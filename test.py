#!/usr/bin/env python3
import paho.mqtt.client as mqtt
from urllib.parse import urlparse
import sys
import time
import json
import schedule

# Define event callbacks
def on_connect(client, userdata, flags, rc, properties):
    print("Connection Result: " + str(rc))

def on_publish(client, obj, mid, rc, properties):
    print("Message ID: " + str(mid))

mqttc = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)

# Assign event callbacks
mqttc.on_connect = on_connect
mqttc.on_publish = on_publish

# Connect
try:
    mqttc.connect("ec2-13-60-15-160.eu-north-1.compute.amazonaws.com", 1883)
    mqttc.loop_start()
except Exception as e:
    print("Connection failed: " + str(e))
    exit(1)

i = 30

def publish_temperature():
    global i
    temp=i / 2
    temp_json=json.dumps({"temperature":temp, "timestamp":time.time()})
    mqttc.publish("epic/temperature", temp_json)
    i += 1

# Publish a message to temp every 10 seconds
schedule.every(1).seconds.do(publish_temperature)

try:
    while True:
        schedule.run_pending()
        time.sleep(1)
except KeyboardInterrupt:
    print("Script termination requested, shutting down.")
finally:
    mqttc.loop_stop()
    mqttc.disconnect()

