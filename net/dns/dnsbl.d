/**
 * Client for DNS blacklist services.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */


module ae.net.dns.dnsbl;

import std.socket;
import std.string;
import ae.net.asockets;

string getIP(string hostname)
{
	try
		return (new InternetAddress(hostname, 0)).toAddrString;
	catch (Exception o)
		return null;
}

int lookupAgainst(string ip, string db)
{
	string[] sections = split(ip, ".");
	assert(sections.length == 4);
	string addr = sections[3] ~ "." ~ sections[2] ~ "." ~ sections[1] ~ "." ~ sections[0] ~ "." ~ db;
	InternetHost ih = new InternetHost;
	if (ih.getHostByName(addr))
		return ih.addrList[0] & 0xFF;
	else
		return 0;
}

string lookupDroneBL(string ip)
{
	switch (lookupAgainst(ip, "dnsbl.dronebl.org"))
	{
		case  0: return null;
		case  2: return "Sample";
		case  3: return "IRC Drone";
		case  5: return "Bottler";
		case  6: return "Unknown spambot or drone";
		case  7: return "DDOS Drone";
		case  8: return "SOCKS Proxy";
		case  9: return "HTTP Proxy";
		case 10: return "ProxyChain";
		case 13: return "Brute force attackers";
		case 14: return "Open Wingate Proxy";
		case 15: return "Compromised router / gateway";
		default: return "Unknown";
	}
}

string lookupEfnetRBL(string ip)
{
	switch (lookupAgainst(ip, "rbl.efnetrbl.org"))
	{
		case  0: return null;
		case  1: return "Open Proxy";
		case  2: return "spamtrap666";
		case  3: return "spamtrap50";
		case  4: return "TOR";
		case  5: return "Drones / Flooding";
		default: return "Unknown";
	}
}

string[] blacklistCheck(string hostname)
{
	string ip = getIP(hostname);
	string result;

	result = lookupDroneBL(ip);
	if (result) return [result, "DroneBL"  , "http://dronebl.org/lookup?ip="~ip];

	result = lookupEfnetRBL(ip);
	if (result) return [result, "EFnet RBL", "http://rbl.efnetrbl.org/?i="  ~ip];

	return null;
}
