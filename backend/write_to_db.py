#!/usr/bin/env python3
import sys, os, time
import ssl

import paho.mqtt.client as mqtt

import influxdb_client
from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS

token = os.environ.get("INFLUXDB_TOKEN")
org = "MEMP"
url = "https://memp-data.duckdns.org:8086"

client = influxdb_client.InfluxDBClient(url=url, token=token, org=org, timeout=30_000)
write_api = client.write_api(write_options=SYNCHRONOUS)

field_names = [
    'AtmosphericPressure',
    'WindDirection',
    'WindSpeed',
    'Gust',
    'WaveHeight',
    'WavePeriod',
    'MeanWaveDirection',
    'Hmax',
    'AirTemperature',
    'DewPoint',
    'SeaTemperature',
    'salinity',
    'RelativeHumidity',
    'SprTp',
    'ThTp',
    'Tp',
    'QC_Flag'
]

def on_message(client, obj, msg):
    s = msg.payload.decode('utf8')
    print(f'Got publish {s}')
    lines = s.split('\n')
    for line in lines:
        if len(line) == 0: continue
        values = line.split(',')
        if len(values) < 22: continue
        print(f'LENGTH: {len(values)}')

        point = Point("temp").tag("station_id", values[1])
        for value, name in zip(values[5:], field_names):
            point = point.field(name, value)
        point = point.time(values[4])

        write_api.write(bucket='guh', record=point)

    print('Write success')


mqttc = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
mqttc.tls_set(tls_version=ssl.PROTOCOL_TLSv1_2)

# Assign event callbacks
mqttc.on_message = on_message

# Connect
print('Connecting to MQTT broker...', end='', flush=True)
try:
    mqttc.connect("iot-mqtt-broker.duckdns.org", 1884)
except Exception as e:
    print("Connection failed: " + str(e))
    exit(1)
print(' Done\nRunning')
try:  
    mqttc.subscribe("station_data")
    mqttc.loop_forever()
except KeyboardInterrupt:
    pass
finally:
    mqttc.loop_stop()
    mqttc.disconnect()
    print("Disconnected from MQTT broker.")
