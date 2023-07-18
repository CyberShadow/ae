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
 *   Vladimir Panteleev <ae@cy.md>
 */


module ae.net.dns.dnsbl;

import std.socket;
import std.string;
import ae.net.asockets;

/// Resolve a hostname to an IPv4 dotted quad.
string getIP(string hostname)
{
	try
		return (new InternetAddress(hostname, 0)).toAddrString;
	catch (Exception o)
		return null;
}

/// Look up an IP address against a specific DNS blacklist.
/// Returns: the numeric code (generally indicating a
/// blacklist-specific list reason).
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

/// Look up an IP address against DroneBL.
/// Returns: a string describing the reason this IP is listed,
/// or `null` if the IP is not listed.
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

/// Look up an IP address against the EFnet RBL.
/// Returns: a string describing the reason this IP is listed,
/// or `null` if the IP is not listed.
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

/// Look up an IP address against the sectoor.de Tor exit node DNSBL.
/// Returns: a string describing the reason this IP is listed,
/// or `null` if the IP is not listed.
string lookupSectoorTorDNSBL(string ip)
{
	switch (lookupAgainst(ip, "exitnodes.tor.dnsbl.sectoor.de"))
	{
		case  0: return null;
		case  1: return "Tor exit node";
		default: return "Unknown";
	}
}

/// Look up an IP address against the dan.me's Tor exit node DNSBL.
/// Returns: a string describing the reason this IP is listed,
/// or `null` if the IP is not listed.
string lookupDanTorDNSBL(string ip)
{
	switch (lookupAgainst(ip, "torexit.dan.me.uk"))
	{
		case   0: return null;
		case 100: return "Tor exit node";
		default : return "Unknown";
	}
}

/// Look up an IP address in all implemented DNS blacklists.
/// Returns: null, or an array with three elements:
/// 0. a string describing the reason this IP is listed
/// 1. the name of the DNS blacklist service
/// 2. an URL with more information about the listing.
string[] blacklistCheck(string hostname)
{
	string ip = getIP(hostname);

	if (!ip)
		throw new Exception("Can't resolve hostname to IPv4 address: " ~ hostname);

	string result;

	result = lookupDroneBL(ip);
	if (result) return [result, "DroneBL"  , "http://dronebl.org/lookup?ip="~ip];

	result = lookupEfnetRBL(ip);
	if (result) return [result, "EFnet RBL", "http://rbl.efnetrbl.org/?i="  ~ip];

	result = lookupSectoorTorDNSBL(ip);
	if (result) return [result, "Sectoor Tor exit node", "http://www.sectoor.de/tor.php"];

	result = lookupDanTorDNSBL(ip);
	if (result) return [result, "Dan Tor exit node", "https://www.dan.me.uk/dnsbl"];

	return null;
}
