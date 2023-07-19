/**
 * Common Matrix code. Experimental!
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

module ae.net.matrix.common;

import ae.utils.json;

struct RoomId { string value; }
struct EventId { string value; }

enum MessageEventType : string
{
	none = null,
	roomMessage = "m.room.message",
}

struct RoomMessage
{
	JSONFragment fragment;

	this(RoomTextMessage m) { fragment.json = m.toJson(); }
}

struct RoomTextMessage
{
	string body;
	string msgtype = "m.text";
}
