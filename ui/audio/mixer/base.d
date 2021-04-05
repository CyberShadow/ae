/**
 * ae.ui.audio.mixer.base
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

module ae.ui.audio.mixer.base;

import ae.ui.audio.source.base;

class Mixer
{
	abstract void playSound(SoundSource sound);
	abstract void fillBuffer(SoundSample[] buffer) nothrow;
}
