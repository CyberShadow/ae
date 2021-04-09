/**
 * ae.ui.audio.audio
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

module ae.ui.audio.audio;

import ae.ui.app.application;
import ae.ui.audio.mixer.base;

/// Abstract audio player interface.
class Audio
{
	Mixer mixer; ///

	/// Start driver (Application dictates settings).
	abstract void start(Application application);

	/// Stop driver (may block).
	abstract void stop();
}
