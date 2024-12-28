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
import ae.utils.array;
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
		{
			// Already in the goal state
			goalPromise.fulfill();
			return;
		}
		// Start a new transition
		newState = goalState;
		currentTransition = stateFunc(goalState)
			.then(&onComplete, &onFail);
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

	void onFail(Exception e)
	{
		assert(currentTransition);
		debug assert(oldState != newState || stateWasReset);
		debug stateWasReset = false;
		currentTransition = null;

		if (newState == goalState)
		{
			// State transition failed.
			// We cannot reach the goal state; give up until further instructions.
			newState = goalState = oldState;
			goalPromise.reject(e);
		}
		else
		{
			// Actually, we now want to go somewhere else.
			// Try again.
			newState = oldState;
			enqueueProd();
		}
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

	/// The promise that will be fulfilled when we reach the goal state.
	Promise!void goalPromise;

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
		/// Accepts the goal state, and returns a promise which is the
		/// resulting (ideally but not necessarily, the goal) state.
		/// If the returned promise is rejected, it indicates that the
		/// state hasn't changed and the goal cannot be reached.
		Promise!State delegate(State) stateFunc,
		/// The initial state.
		State initialState = State.init,
	)
	{
		this.stateFunc = stateFunc;
		this.oldState = this.newState = this.goalState = initialState;
		goalPromise = resolve();
	}

	/// Set the goal state.  Starts off a transition operation if needed.
	/// Returns a promise that will be fulfilled when we reach the goal state,
	/// or rejected if the goal state changes before it is reached.
	Promise!void setGoal(State state)
	{
		if (goalState != state)
		{
			if (currentTransition || newState != goalState)
				goalPromise.reject(new Exception("Goal changed"));
			goalPromise = new Promise!void;

			this.goalState = state;
			enqueueProd();
		}
		return goalPromise;
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
debug(ae_unittest) unittest
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

	q.setGoal(1).ignoreResult();
	q.setGoal(2).ignoreResult();
	socketManager.loop();
	assert(state == 2 && workDone == 1);
}

// Test incremental transitions towards the goal
debug(ae_unittest) unittest
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

	q.setGoal(3).ignoreResult();
	socketManager.loop();
	assert(state == 3 && workDone == 3);
}


/// A wrapper around a `StateQueue` which modifies its behavior, such
/// that:
/// 1. After a transition to a state completes, a temporary "lock" is
///    obtained, which blocks any transitions while it is held;
/// 2. Transition requests form a queue of arbitrary length.
struct LockingStateQueue(
	/// A type representing the state.
	State,
	/// If `true`, guarantee that requests for a certain goal state will
	/// be satisfied strictly in the order that they were requested.
	/// If `false` (default), requests for a certain state may be
	/// grouped together and satisfied out-of-order.
	bool strictlyOrdered = false,
)
{
private:
	StateQueue!State stateQueue;

	struct DesiredState
	{
		State state;
		Promise!Lock[] callbacks;
	}
	DesiredState[] desiredStates;

	bool isLocked;
	debug size_t lockIndex;

	Lock acquire()
	{
		assert(!isLocked);

		Lock lock;
		debug lock.lockIndex = ++lockIndex;
		isLocked = true;

		return lock;
	}

	void prod()
	{
		if (isLocked)
			return; // Waiting for .release() -> .prod()

		// Drain fulfilled queued states
		while (desiredStates.length > 0 && desiredStates[0].callbacks.length == 0)
			desiredStates = desiredStates[1 .. $];

		if (desiredStates.length == 0)
			return; // Nothing to do

		// Acquire the lock now, whether we are transitioning to another state,
		// or immediately resolving a callback.
		auto lock = acquire();
		step(lock);
	}

	void step(Lock lock)
	{
		assert(desiredStates.length > 0);

		// StateQueue should be idle
		assert(stateQueue.oldState == stateQueue.newState && stateQueue.newState == stateQueue.goalState);

		// Check for matches in the queue
		size_t maxIndex = strictlyOrdered ? 1 : desiredStates.length;
		foreach (ref desiredState; desiredStates[0 .. maxIndex])
			if (desiredState.state == stateQueue.newState)
			{
				auto callback = desiredState.callbacks.queuePop();
				callback.fulfill(lock);
				// Execution will be resumed when .resume() is called with the lock
				return;
			}

		// No matches in the queue? Go to the next queued goal state
		stateQueue
			.setGoal(desiredStates[0].state)
			.then({
				// TODO: if stateFunc moved incrementally but not fully towards goalState,
				// this could still be useful for us when strictlyOrdered is false and
				// this intermediary state is in the queue. However, currently StateQueue
				// only resolves its returned promise when goalState is reached.

				// Re-check queue
				step(lock);
			})
			.except((Exception e) {
				// On a transition error, drain all queued states
				auto queue = desiredStates;
				desiredStates = null;
				foreach (ref desiredState; queue)
					foreach (callback; desiredState.callbacks)
						callback.reject(e);
				release(lock);
			});
	}

public:
	/// Constructor.
	this(
		/// The function implementing the state transition operation.
		/// Accepts the goal state, and returns a promise which is the
		/// resulting (ideally but not necessarily, the goal) state.
		Promise!State delegate(State) stateFunc,
		/// The initial state.
		State initialState = State.init,
	)
	{
		this.stateQueue = StateQueue!State(stateFunc, initialState);
	}

	/// Represents a held lock.
	/// The lock is acquired automatically when a desired state is reached.
	/// To release the lock, call `.release` on the queue object.
	struct Lock
	{
		debug private size_t lockIndex;
	}

	/// Enqueue a desired goal state.
	Promise!Lock addGoal(State state)
	{
		scope(success) prod();
		auto p = new Promise!Lock();
		static if (!strictlyOrdered)
			foreach (ref desiredState; desiredStates)
				if (desiredState.state == state)
				{
					desiredState.callbacks ~= p;
					return p;
				}
		desiredStates ~= DesiredState(state, [p]);
		return p;
	}

	/// Relinquish the lock, allowing a transition to a different state.
	void release(Lock lock)
	{
		assert(isLocked, "Attempting to release a lock when one is not held");
		debug assert(lockIndex == lock.lockIndex, "Attempting to release a mismatching lock");

		isLocked = false;
		prod();
	}

	/// These may be useful to access in stateFunc.
	@property State oldState() { return stateQueue.oldState; }
	@property State newState() { return stateQueue.newState; } /// ditto
	@property State goalState() { return stateQueue.goalState; } /// ditto
}

debug(ae_unittest) unittest
{
	import ae.utils.promise.timing : sleep;

	Promise!int changeState(int i)
	{
		return sleep(1.msecs).then({ 
			return i;
		});
	}

	static foreach (bool strictlyOrdered; [false, true])
	{{
		auto q = LockingStateQueue!(int, strictlyOrdered)(&changeState);

		int[] goals;
		void addGoal(int goal)
		{
			q.addGoal(goal).then((lock) {
				goals ~= goal;
				q.release(lock);
			});
		}
		addGoal(1);
		addGoal(2);
		addGoal(1);
		socketManager.loop();
		auto expectedGoals = strictlyOrdered ? [1, 2, 1] : [1, 1, 2];
		assert(goals == expectedGoals);
	}}
}
