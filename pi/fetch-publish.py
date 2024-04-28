#!/usr/bin/env python3
import requests
import json
import urllib.parse

import paho.mqtt.client as mqtt
import schedule
import time
import sys

def fetch_data():
  res = requests.get(f'https://erddap.marine.ie/erddap/tabledap/IWBNetwork.csv?{query}')
  if not res.ok:
      print(f'ERROR {res.status_code}')
      return None

  return res.content.decode('utf8')

def publish_data():
    data = fetch_data()
    if data is None: return

    lines = data.split('\n')
    for line in lines[2:]: # Skip first two lines, which are the column names and measurement units
        if len(line) == 0: continue

        values = line.split(',')
        print(f'publishing on stations/{values[0]}: {line}')
        mqttc.publish(f'stations/{values[0]}', line)

# See https://erddap.marine.ie/erddap/rest.html and
# https://erddap.marine.ie/erddap/tabledap/documentation.html
# for request documentation

# The stations take a reading every hour.
# Stations M2 to M6 are the only stations currently active,
# so match `station_id` against the regex `M[2-6]`.

# `orderByMax` first groups rows by `station_id`,
# then gets the row for each group that has the most recent `time` value.

query = urllib.parse.quote_plus('&station_id=~"M[2-6]"&orderByMax("station_id,time")')

mqttc = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)

try:
    mqttc.connect("ec2-13-60-15-160.eu-north-1.compute.amazonaws.com", 1883)
    # mqttc.connect("127.0.0.1", 1883)
    mqttc.loop_start()
except Exception as e:
    print("Connection failed: " + str(e))
    exit(1)

schedule.every(30).minutes.do(publish_data)

try:
    while True:
        schedule.run_pending()
        time.sleep(10)
except KeyboardInterrupt:
    pass
finally:
    mqttc.loop_stop()
    mqttc.disconnect()

