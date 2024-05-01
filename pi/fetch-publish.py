#!/usr/bin/env python3
import requests
import json
import urllib.parse

import paho.mqtt.client as mqtt
import ssl
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

    # Remove first two lines, which are the column names and measurement units
    data = data.split('\n', 2)[2]
    mqttc.publish("station_data", data)

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
mqttc.tls_set('/etc/ssl/certs/ca-certificates.crt', tls_version=ssl.PROTOCOL_TLSv1_2)

try:
    print('Connecting to MQTT broker...', end='', flush=True)
    mqttc.connect("iot-mqtt-broker.duckdns.org", 1884)
    print(' Done')
    mqttc.loop_start()
except Exception as e:
    print("Connection failed: " + str(e))
    exit(1)

schedule.every(30).minutes.do(publish_data)

try:
    print('Running...', end='', flush=True)
    while True:
        schedule.run_pending()
        time.sleep(10)
except KeyboardInterrupt:
    pass
finally:
    print(' Done')
    mqttc.loop_stop()
    mqttc.disconnect()

