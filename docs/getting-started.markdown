---
layout: page
title: Getting Started
permalink: /getting-started/
---

## Overview

MEMP manages the data flow from sensor-gateway to the end consumers web browser. MEMP ingests marine
data from ERDDAP servers, cataloguing it in a time-series database and presents it to the end user.

## Requirements

- Command line familiarity
- A gateway device (any computer with internet access)
- Server to host an MQTT broker
- Server to host the database backend

## Getting a Domain (optional)

This step is required for using TLS, which is highly recommended. However, it is possible for MEMP
to function purely over unencrypted HTTP. If you do not desire traffic encryption you can skip
these steps.

The easiest way to get a domain name is to use a dynamic DNS provider. These provide subdomains
which you can point to your servers IP address, and you can get TLS certificates for these domains.

You can use any service you like, but I find [DuckDNS](https://duckdns.org) to be very easy to use.
Sign up for an account and you will be presented with a generated token - keep this for later.
You can then add a subdomain and an IP address to point it to. It may take a few minutes for the
subdomain to properly point to the address.

## Generating Certificates (optional)

This step will be done multiple times during the setup. Certificates are necessary to enable TLS
encryption for web traffic to the MQTT broker and the Grafana webview. This step is not required
for MEMP to function, but it is highly recommended to follow it.

This guide focuses on creating signed certificates with letsencrypt. Self-signed certificates can
be used but are not the focus here.

We will use (acme.sh)[https://github.com/acmesh-official/acme.sh] to generate and manage our
certificates. Install acme.sh via the following command:

```bash
$ curl https://get.acme.sh | sh -s
```

Restart your shell. Set the default certificate authority to letsencrypt:

```bash
$ acme.sh --set-default-ca --server letsencrypt
```

Issue a certificate for your domain like so, replacing 'yourdomain.duckdns.org' with your domain.

```bash
$ acme.sh --issue --dns dns_duckdns --domain yourdomain.duckdns.org
```

If you are not using duckdns, consult the acme.sh documentation for the correct dns string to
pass. Install the certificate files to the current directory.

```bash
$ acme.sh --install-cert --domain yourdomain.duckdns.org --cert-file "certificate.pem" --fullchain-file "fullchain.pem" --key-file "key.pem"
```

## MQTT Broker

[Mosquitto](https://github.com/eclipse/mosquitto) will be used as the MQTT broker of choice, though
any broker could be used. The easiest way to set up Mosquitto is on an AWS EC-2 instance, but again
any server with internet access could be used. Amazon Linux does not ship Mosquitto in their
repos, so we will build it from source.

First, install build essentials:

```bash
$ sudo yum update && sudo yum install -y cmake openssl-devel libxslt
```

Download the mosquitto source tarball [here](https://mosquitto.org/download/) and decompress it with:

```bash
$ tar -xf mosquitto-*.tar.gz
```

`cd` into the new directory and run the following commands to build Mosquitto:

```bash
$ cmake .
$ make
$ sudo make install
```

Mosquitto will be installed to `/usr/local` and can be run via the `mosquitto` binary. Mosquitto
will work without any further configuration, however it's a good idea to enable TLS to encrypt
traffic.

Edit `/usr/local/etc/mosquitto/mosquitto.conf`, adding the following lines to the top:

```conf
listener 1883
allow_anonymous true
```

To enable TLS encryption, modify `/usr/local/share/mosquitto/mosquitto.conf` to point to the
certificates. The user running Mosquitto will need to have read permissions on the certificate
files.

```conf
listener 1884
allow_anonymous true
cafile /path/to/fullchain.pem
certfile /path/to/certificate.pem
keyfile /path/to/key.pem
```

Note how the port number has been changed to 1884. By convention, unencrypted MQTT traffic goes
through port 1883, and encrypted traffic goes through port 1884. The Mosquitto binary can then be
run:

```bash
$ mosquitto
```

You should now have a working MQTT broker!

## Publishing Data

# Getting Data from ERDDAP

ERDDAP exposes a REST API for querying data. ERDDAP instances all host the documentation for the
API, under the subpath `tabledap/documentation.html`. For example, [here](https://erddap.marine.ie/
erddap/tabledap/documentation.html) is the documentation page on the [marine.ie](https://marine.ie)
site.

ERDDAP data can be queried from `/tabledap/IWBNetwork.csv`. Parameters can be appended following a
'?' characters to narrow the returned data. ERDDAP supports returning data in many formats, but only
CSV will be used here. For the format required by MEMP, append to the url:

```
?&station_id=~"REGEX"&orderByMax("station_id,time")
```

Replace 'REGEX' with a regular expression to match against station ids. The `orderByMax` function
gets the most recent datapoint for each station.

Note that many characters need to be percent escaped to be used in ERDDAP queries. In Python you can
use `urllib.parse.quote_plus` to do this escaping. For exactly what characters need to be escaped,
consult the ERDDAP documentation.

This will return the most recent datapoints for each station matching 'REGEX', with one station per
line and different measurements separated by commas.

Example output:

```csv
station_id,CallSign,longitude,latitude,time,AtmosphericPressure,WindDirection,WindSpeed,Gust,WaveHeight,WavePeriod,MeanWaveDirection,Hmax,AirTemperature,DewPoint,SeaTemperature,salinity,RelativeHumidity,SprTp,ThTp,Tp,QC_Flag
,,degrees_east,degrees_north,UTC,millibars,degrees true,knots,knots,meters,seconds,degrees_true,meters,degrees_C,degrees_C,degrees_C,dimensionless,percent,degrees,degrees_true,seconds,
M4,62093,-9.999136,54.999967,2024-05-02T02:00:00Z,1011.914,63.0,9.108,11.84,1.523,5.977,354.0,2.5,11.045,NaN,11.157,34.97231,88.281,149.063,333.281,9.141,0
M5,62094,-6.704336,51.690425,2024-05-02T02:00:00Z,1009.119,34.0,11.385,13.889,1.055,4.922,208.0,1.563,10.947,NaN,11.559,NaN,84.18,203.906,222.188,6.68,0
M6,62095,-15.88135,53.07482,2024-05-02T02:00:00Z,1008.789,101.0,10.36,13.548,2.461,6.914,0.0,4.219,10.898,NaN,11.744,35.55382,75.293,112.5,351.563,9.961,0
```

The first two lines are unused by MEMP and should not be published to MQTT. MEMP expects these exact
22 values for each datapoint. Lines with less than 22 lines are discarded. MEMP supports publishing
multiple datapoints at once, separated by newlines.

# Using fetch-publish.py

MEMP provides a script to automate this for you. Simply change the hardcoded ERDDAP server URL in
the python script to your ERDDAP server, and the MQTT broker URL to your duckdns subdomain and you
should be ready to go.

`fetch-publish` runs continuously, and fetches and publishes data every 30 minutes. This interval
can be changed in the source code to lower or higher values if you wish.

This script will be updated to accept these values as arguments, rather than having to edit source
code.

You should see output from your MQTT broker displaying connections and published messages.

## Setting up the Database

MEMP supports using SQLite or InfluxDB as database backends. When possible it is preferable to run
InfluxDB, however limited hardware resources with small datasets may run better on SQLite.

InfluxDB is preferred due to being a time series database, which is highly optimized for the exact
type of data that MEMP collects. InfluxDB also has very easy to use downsampling capabilities, which
are essential for large datasets. Downsampling in SQLite is much more complicated and is not covered
here.

# SQLite

The SQLite driver is written in [Zig](https://ziglang.org). Why? Because it is. Install Zig 0.12
from [here](https://ziglang.org/download). Decompress it with tar and the resulting directory will
have the `zig` compiler binary. Clone the repo and run the following command to build the driver:

```bash
$ cd memp/backend && zig build -Doptimize=ReleaseSafe --summary all
```

This will output a binary to `zig-out/bin/backend`. This binary expects two arguments: The MQTT
broker URL and the path to the SQLite database file. The database file will be created if it does
not exist. You should create the database file in a location where other users will be able to read
it, which will be needed later. A good location might be a directory in `/opt`.

# InfluxDB (preferred)

Download InfluxDB [here](https://www.influxdata.com/downloads/). For Amazon Linux, select
'RedHat & CentOS' as the platform. Install 'InfluxDB 2.x' and 'InfluxDB v2 Cloud CLI.'

Start the influxd service:

```bash
$ sudo systemctl start influxd
```

To run influxd on startup:

```bash
$ sudo systemctl enable influxd
```

Remember those certificates we generated? If you're running the database on a separate server to the
MQTT broker (recommended), you will need to generate new ones. Get another subdomain from duckdns
and repeat the process on this machine. Edit `/etc/influxdb/config.toml` to include the following
lines:

```toml
tls-cert="/path/to/fullchain.pem"
tls-key="/path/to/key.pem"
```

Restart influxd:

```bash
$ sudo systemctl restart influxd
```

You can now setup InfluxDB with the CLI tool.

```bash
$ influx setup
```

And follow the instructions. The InfluxDB driver is written in python, and is located at `backend/
influx.py`. Your influx token will be needed to run the script. Your token can be found via

```bash
$ influx auth list
```

Then export the token as an environment variable:

```bash
$ export INFLUXDB_TOKEN='copy-pasted-token'
```

Run the database driver like so:

```bash
$ backend/influx.py
```

This should listen for MQTT messages and write datapoints to the InfluxDB database.

Open port 8086 on this machine. For an EC-2 instance this can be done by editing the **inbound
rules** in the instances security group. You should be able to access the InfluxDB webview over
HTTPS. Log in using the credentials you supplied when setting up and you can poke around in the
webview.

If you encounter any trouble in this step, you can use `journalctl -u influxd` to see log messages
for influxd.

## Grafana

[Grafana](https://grafana.com/grafana/) is a web server and frontend for monitoring and visualizing
data. Here we use it as the primary way to monitor our data.

To install Grafana on Amazon Linux:

```bash
$ sudo yum install -y https://dl.grafana.com/oss/release/grafana-10.4.2-1.x86_64.rpm
```

Grafana needs to be configured to use https. Add these lines to `/etc/grafana/grafana.ini`:

```ini
protocol = https
cert_file = /path/to/fullchain.pem
cert_key = /path/to/key.pem
```

The certificate files need the correct permissions for Grafana to be able to read them. You can
check if Grafana is able to read them by running `$ sudo journalctl -u grafana-server` after
restarting grafana.

Enable the service on startup:

```bash
sudo systemctl start grafana-server && sudo systemctl enable grafana-server
```

You should now be able to view the Grafana webview on port 3000 over https. You can optionally
redirect traffic from port 443 (https) to 3000 with this command:

```bash
$ sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 3000
```

## Add a Data Source

In the Grafana webview, click 'Connections' in the sidebar and add a new data source. Pick either
SQLite or InfluxDB based on what database you used. The InfluxDB configuration will need your login
and token to authenticate.

Go to the 'explore' tag in the sidebar, where you can query and graph your data. An example
SQLite query:

```sql
SELECT station_id, time, air_temperature FROM datapoints
WHERE time >= $__from / 1000 and time < $__to / 1000
```

An example InfluxDB query:

```flux
from(bucket: "MEMP")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "temp")
  |> filter(fn: (r) => r["_field"] == "AirTemperature")
  |> filter(fn: (r) => r["station_id"] == "M2" or r["station_id"] == "M3" or r["station_id"] == "M4" or r["station_id"] == "M5" or r["station_id"] == "M6")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
  |> yield(name: "mean")
```

You can then create a dashboard to visualize your data. The UI is easy to use and self explanatory,
so I'll refrain from explaining it here.
