/**
 * ae.ui.shell.events
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

module ae.ui.shell.events;

/// Mouse button indices.
enum MouseButton : ubyte
{
	Left,       ///
	Right,      ///
	Middle,     ///
	WheelUp,    ///
	WheelDown,  ///
}

/// Mouse button mask.
enum MouseButtons : ubyte
{
	None      =    0, ///
	Left      = 1<<0, ///
	Right     = 1<<1, ///
	Middle    = 1<<2, ///
	WheelUp   = 1<<3, ///
	WheelDown = 1<<4, ///
}

/// A few key definitions.
enum Key
{
	unknown  , ///
	esc      , ///
	up       , ///
	down     , ///
	left     , ///
	right    , ///
	pageUp   , ///
	pageDown , ///
	home     , ///
	end      , ///
	space    , ///
}

/// Joystick/D-pad directions.
enum JoystickHatState
{
	up    = 1, ///
	right = 2, ///
	down  = 4, ///
	left  = 8, ///
}
