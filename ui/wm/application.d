/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

module ae.ui.wm.application;

import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.events;
import ae.ui.wm.controls.root;
import ae.ui.video.surface;

/// Specialization of Application class which automatically handles framework messages.
class WMApplication : Application
{
	RootControl root;

	this()
	{
		root = new RootControl();
	}

	// ****************************** Event handlers *******************************

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		root.handleMouseDown(x, y, button);
	}

	override void handleMouseUp(uint x, uint y, MouseButton button)
	{
		root.handleMouseUp(x, y, button);
	}

	override void handleMouseMove(uint x, uint y, MouseButtons buttons)
	{
		root.handleMouseMove(x, y, buttons);
	}

	override void handleQuit()
	{
		shell.quit();
	}

	// ********************************* Rendering *********************************

	override void render(Surface s)
	{
		root.render(s, 0, 0);
	}
}
