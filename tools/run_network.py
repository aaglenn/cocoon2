#!/usr/bin/python

# Based on the topo.py script from the P4 tutorial

# Copyright 2013-present Barefoot Networks, Inc. 
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from mininet.net import Mininet
from mininet.topo import Topo
from mininet.log import setLogLevel, info
from mininet.cli import CLI
from mininet.link import TCLink
import json

from p4_mininet import P4Switch, P4Host

import argparse
from time import sleep
import os
import subprocess

_THIS_DIR = os.path.dirname(os.path.realpath(__file__))
_THRIFT_BASE_PORT = 22222

parser = argparse.ArgumentParser(description='Mininet demo')
parser.add_argument('--behavioral-exe', help='Path to behavioral executable',
                    type=str, action="store", required=True)
parser.add_argument('--mn', help='Path to JSON MiniNet topology file',
                    type=str, action="store", required=True)
parser.add_argument('--cli', help='Path to BM CLI',
                    type=str, action="store", required=True)
parser.add_argument('--p4c', help='Path to P4C-to-json compiler',
                    type=str, action="store", required=True)

args = parser.parse_args()

class MyTopo(Topo):
    def __init__(self, sw_path, topology, netname, netdir, **opts):
        # Initialize topology and default options
        Topo.__init__(self, **opts)

        thrift_port = _THRIFT_BASE_PORT

        for sw in topology['switches']:
            hostname = sw['opts']['hostname']
            switch = self.addSwitch(hostname,
                                    sw_path     = sw_path,
                                    json_path   = os.path.join(netdir, netname) + '.' + hostname + '.' + 'json',
                                    thrift_port = _THRIFT_BASE_PORT + sw['opts']['nodeNum'],
                                    pcap_dump   = True,
                                    device_id   = sw['opts']['nodeNum'])

        for h in topology['hosts']:
            host = self.addHost(h['opts']['hostname'])

        for link in topology['links']:
            self.addLink(link['src'], link['dest'], port1 = link['srcport'], port2 = link['destport'])

def main():

    mnfile = open(args.mn, "r")
    loadedTopology = json.load(mnfile)
    netdir, fname = os.path.split(args.mn)
    netname, fextension = os.path.splitext(fname)

    # convert .p4 switches to json
    for sw in loadedTopology['switches']:
        hostname = sw['opts']['hostname']
        cmd = [args.p4c, 
               os.path.join(netdir, netname) + '.' + hostname + '.' + 'p4', 
               "--json", os.path.join(netdir, netname) + '.' + hostname + '.' + 'json']
        print " ".join(cmd)
        try:
            output = subprocess.check_output(cmd)
            print output
        except subprocess.CalledProcessError as e:
            print e

    # build mininet topology
    topo = MyTopo(args.behavioral_exe, loadedTopology, netname, netdir)

    net = Mininet(topo = topo,
                  host = P4Host,
                  switch = P4Switch,
                  controller = None )
    net.start()

    # configure hosts
    for n in loadedTopology['hosts']:
        h = net.get(n['opts']['hostname'])
        for off in ["rx", "tx", "sg"]:
            cmd = "/sbin/ethtool --offload eth0 %s off" % off
            print cmd
            h.cmd(cmd)
        print "disable ipv6"
        h.cmd("sysctl -w net.ipv6.conf.all.disable_ipv6=1")
        h.cmd("sysctl -w net.ipv6.conf.default.disable_ipv6=1")
        h.cmd("sysctl -w net.ipv6.conf.lo.disable_ipv6=1")
        h.cmd("sysctl -w net.ipv4.tcp_congestion_control=reno")
        h.cmd("iptables -I OUTPUT -p icmp --icmp-type destination-unreachable -j DROP")

    sleep(1)

    # configure switches
    for sw in loadedTopology['switches']:
        hostname = sw['opts']['hostname']
        cmd = [args.cli, "--json", os.path.join(netdir, netname) + '.' + hostname + '.' + 'json',
               "--thrift-port", str(_THRIFT_BASE_PORT + sw['opts']['nodeNum'])]
        with open(os.path.join(netdir, netname) + '.' + hostname + '.' + 'txt', "r") as f:
            print " ".join(cmd)
            try:
                output = subprocess.check_output(cmd, stdin = f)
                print output
            except subprocess.CalledProcessError as e:
                print e
                print e.output

    sleep(1)

    CLI( net )
    net.stop()

if __name__ == '__main__':
    setLogLevel( 'info' )
    main()