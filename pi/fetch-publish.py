#!/usr/bin/env python3
import requests
import json
import urllib.parse

import paho.mqtt.client as mqtt
import schedule
import time
import sys

# See https://erddap.marine.ie/erddap/rest.html and
# https://erddap.marine.ie/erddap/tabledap/documentation.html
# for request documentation

# The stations take a reading every hour.
# Stations M2 to M6 are the only stations currently active,
# so match `station_id` against the regex `M[2-6]`.

# `orderByMax` first groups rows by `station_id`,
# then gets the row for each group that has the highest `time` value.

query = urllib.parse.quote_plus('&station_id=~"M[2-6]"&orderByMax("station_id,time")')

mqttc = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)

try:
    mqttc.connect("ec2-13-60-15-160.eu-north-1.compute.amazonaws.com", 1883)
    # mqttc.connect("127.0.0.1", 1883)
    mqttc.loop_start()
except Exception as e:
    print("Connection failed: " + str(e))
    exit(1)

def fetch_data():
    res = requests.get(f'https://erddap.marine.ie/erddap/tabledap/IWBNetwork.json?{query}')
    if not res.ok:
        print(f'ERROR {res.status_code}')
        return None

    return json.loads(res.content)

def publish_data():
    for row in data['table']['rows']:
        mqttc.publish(f'stations/{row[0]}', json.dumps(row))

schedule.every(30).minutes.do(publish_data)

try:
    while True:
        schedule.run_pending()
        time.sleep(30)
except KeyboardInterrupt:
    print("Script termination requested, shutting down.")
finally:
    mqttc.loop_stop()
    mqttc.disconnect()

