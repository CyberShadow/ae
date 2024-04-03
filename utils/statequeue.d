/**
 * ae.utils.statequeue
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

module ae.utils.statequeue;

import core.time;

import ae.net.asockets;
import ae.utils.promise;

/**
   Let `f(x)` be an expensive operation which changes something to
   (or towards) state `x`.  At most one `f` call may be in progress at any time.
   This type orchestrates a series of operations that eventually bring
   the state to some goal, while allowing the goal to change at any time.
 */
struct StateQueue(State)
{
private:
	bool prodPending;

	// Flag to aid the debug invariant.
	// Normally (oldState == newState) == (currentTransition is null).
	// One exception to that is when a transition from an invalid state started,
	// and setCurrentState was called during the transition,
	// so we're "transitioning" from an invalid to an invalid state.
	debug bool stateWasReset;

	void enqueueProd()
	{
		if (prodPending)
			return;
		prodPending = true;
		socketManager.onNextTick(&prod);
	}

	void prod()
	{
		prodPending = false;
		if (currentTransition)
			return; // Will be picked up in onComplete
		assert(oldState == newState);
		if (newState == goalState)
			return; // Already in the goal state
		// Start a new transition
		newState = goalState;
		currentTransition = stateFunc(goalState)
			.then(&onComplete);
	}

	void onComplete(State resultState)
	{
		assert(currentTransition);
		debug assert(oldState != newState || stateWasReset);
		debug stateWasReset = false;
		oldState = newState = resultState;
		currentTransition = null;

		prod();
	}

public:
	@disable this();

	/// The asynchronous implementation function which actually changes the state.
	Promise!State delegate(State) stateFunc;

	/// The state that any current change is moving away from.
	State oldState;

	/// The state that any current change is moving towards.
	State newState;

	/// The final state that we want to be in.
	State goalState;

	/// The current state transition.
	Promise!void currentTransition;

	debug invariant
	{
		if (currentTransition)
			assert(oldState != newState || stateWasReset);
		else
			assert(oldState == newState);
	}

	/// Constructor.
	this(
		/// The function implementing the state transition operation.
		/// Accepts the goal state, and returns a promise which is
		/// the resulting (ideally but necessarily, the goal) state.
		Promise!State delegate(State) stateFunc,
		/// The initial state.
		State initialState = State.init,
	)
	{
		this.stateFunc = stateFunc;
		this.oldState = this.newState = this.goalState = initialState;
	}

	/// Set the goal state.  Starts off a transition operation if needed.
	void setGoal(State state)
	{
		this.goalState = state;
		enqueueProd();
	}

	/// Can be used to indicate that the state has been changed externally
	/// (e.g. to some "invalid"/"dirty" state).
	/// If a transition operation is already in progress, assume that it will
	/// change the state to the given state instead of its actual goal.
	void setCurrentState(State state = State.init)
	{
		if (currentTransition)
		{
			newState = state;
			debug stateWasReset = true;
		}
		else
		{
			oldState = newState = state;
			enqueueProd();
		}
	}
}

// Test changing the goal multiple times per tick
version(ae_unittest) unittest
{
	import ae.utils.promise.timing : sleep;

	int state, workDone;
	Promise!int changeState(int i)
	{
		return sleep(1.msecs).then({
			workDone++;
			state = i;
			return i;
		});
	}

	auto q = StateQueue!int(&changeState);
	assert(workDone == 0);

	q.setGoal(1);
	q.setGoal(2);
	socketManager.loop();
	assert(state == 2 && workDone == 1);
}

// Test incremental transitions towards the goal
version(ae_unittest) unittest
{
	import ae.utils.promise.timing : sleep;

	int state, workDone;
	Promise!int changeState(int i)
	{
		return sleep(1.msecs).then({
			workDone++;
			auto nextState = state + 1;
			state = nextState;
			return nextState;
		});
	}

	auto q = StateQueue!int(&changeState);
	assert(workDone == 0);

	q.setGoal(3);
	socketManager.loop();
	assert(state == 3 && workDone == 3);
}
