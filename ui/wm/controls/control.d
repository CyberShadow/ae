/**
 * ae.ui.wm.controls.control
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

module ae.ui.wm.controls.control;

import ae.ui.shell.events;
import ae.ui.video.renderer;

/// Root control class.
class Control
{
	int x, y, w, h;

	void handleMouseDown(int x, int y, MouseButton button) {}
	void handleMouseUp(int x, int y, MouseButton button) {}
	void handleMouseMove(int x, int y, MouseButtons buttons) {}

	abstract void render(Renderer r, int x, int y);

	final @property ContainerControl parent()
	{
		return _parent;
	}

	final @property void parent(ContainerControl newParent)
	{
		if (_parent)
			_parent._removeChild(this);
		_parent = newParent;
		_parent._addChild(this);
	}

	/// rw and rh are recommended (hint) sizes that the parent is allocating to the child,
	/// but there is no obligation to follow them.
	protected void arrange(int rw, int rh) { }

	/// Called when a child's dimensions change, to allow the size change to bubble up to parents.
	final void rearrange()
	{
		auto oldW = w, oldH = h;
		arrange(w, h);
		if (parent && (w != oldW || h != oldH))
			parent.rearrange();
	}

private:
	ContainerControl _parent;
}

// ***************************************************************************

/// An abstract base class for a control with children.
class ContainerControl : Control
{
	final Control controlAt(int x, int y)
	{
		foreach (child; children)
			if (x>=child.x && x<child.x+child.w && y>=child.y && y<child.y+child.h)
				return child;
		return null;
	}

	override void handleMouseDown(int x, int y, MouseButton button)
	{
		auto child = controlAt(x, y);
		if (child)
			child.handleMouseDown(x-child.x, y-child.y, button);
	}

	override void handleMouseUp(int x, int y, MouseButton button)
	{
		auto child = controlAt(x, y);
		if (child)
			child.handleMouseUp(x-child.x, y-child.y, button);
	}

	override void handleMouseMove(int x, int y, MouseButtons buttons)
	{
		auto child = controlAt(x, y);
		if (child)
			child.handleMouseMove(x-child.x, y-child.y, buttons);
	}

	override void render(Renderer s, int x, int y)
	{
		// background should be rendered by a subclass or parent
		foreach (child; children)
			child.render(s, x+child.x, y+child.y);
	}

	final @property Control[] children()
	{
		return _children;
	}

	final typeof(this) addChild(Control control)
	{
		control.parent = this;
		return this;
	}

private:
	// An array should be fine, performance-wise.
	// UI manipulations should be infrequent.
	Control[] _children;

	final void _addChild(Control target)
	{
		_children ~= target;
	}

	final void _removeChild(Control target)
	{
		foreach (i, child; _children)
			if (child is target)
			{
				_children = _children[0..i] ~ _children[i+1..$];
				return;
			}
		assert(false, "Attempting to remove inexisting child");
	}
}

/// Container with static child positions.
/// Does not rearrange its children.
/// Dimensions are bound by the lowest/right-most child.
class StaticFitContainerControl : ContainerControl
{
	override void arrange(int rw, int rh)
	{
		int maxX, maxY;
		foreach (child; children)
		{
			maxX = max(maxX, child.x + child.w);
			maxY = max(maxY, child.y + child.h);
		}
		w = maxX;
		h = maxY;
	}
}

// ***************************************************************************

/// Allow specifying a size as a combination of parent size % and pixels.
/// Sizes are summed together.
struct RelativeSize
{
	int px;
	float ratio;
	// TODO: Add "em", when we have variable font sizes?

	int toPixels(int parentSize) pure const { return px + cast(int)(parentSize*ratio); }

	RelativeSize opBinary(string op)(RelativeSize other)
		if (op == "+" || op == "-")
	{
		return mixin("RelativeSize(this.px"~op~"other.px, this.ratio"~op~"other.ratio)");
	}
}

/// Usage: 50.px
@property RelativeSize px(int px) { return RelativeSize(px, 0); }
/// Usage: 25.percent
@property RelativeSize percent(float percent) { return RelativeSize(0, percent/100f); }

// ***************************************************************************

/// No-op wrapper
class Wrapper : ContainerControl
{
	override void arrange(int rw, int rh)
	{
		assert(children.length == 1, "Wrapper does not have exactly one child");
		auto child = children[0];
		child.arrange(rw, rh);
		this.w = child.w;
		this.h = child.h;
	}
}


/// Provides default implementations for wrapper behavior methods
mixin template ComplementWrapperBehavior(alias WrapperBehavior, Params...)
{
final:
	mixin WrapperBehavior;

	void moreMagic() {}

	static if (!is(typeof(adjustHint)))
		int adjustHint(int hint, Params params) { return hint; }
	static if (!is(typeof(adjustSize)))
		int adjustSize(int size, int hint, Params params) { return size; }
	static if (!is(typeof(adjustPos)))
		int adjustPos(int pos, int size, int hint, Params params) { return pos; }
}

mixin template OneDirectionCustomWrapper(alias WrapperBehavior, Params...)
{
	private Params params;
	static if (Params.length)
		this(Params params)
		{
			this.params = params;
		}

	/// Declares adjustHint, adjustSize, adjustPos
	mixin ComplementWrapperBehavior!(WrapperBehavior, Params);
}

class WCustomWrapper(alias WrapperBehavior, Params...) : Wrapper
{
	override void arrange(int rw, int rh)
	{
		assert(children.length == 1, "Wrapper does not have exactly one child");
		auto child = children[0];
		child.arrange(adjustHint(rw, params), rh);
		this.w = adjustSize(child.w, rw, params);
		this.h = child.h;
		child.x = adjustPos(child.x, child.w, rw, params);
	}

	mixin OneDirectionCustomWrapper!(WrapperBehavior, Params);
}

class HCustomWrapper(alias WrapperBehavior, Params...) : Wrapper
{
	override void arrange(int rw, int rh)
	{
		assert(children.length == 1, "Wrapper does not have exactly one child");
		auto child = children[0];
		child.arrange(rw, adjustHint(rh, params));
		this.w = child.w;
		this.h = adjustSize(child.h, rh, params);
		child.y = adjustPos(child.y, child.h, rh, params);
	}

	mixin OneDirectionCustomWrapper!(WrapperBehavior, Params);
}

class CustomWrapper(alias WrapperBehavior, Params...) : Wrapper
{
	override void arrange(int rw, int rh)
	{
		assert(children.length == 1, "Wrapper does not have exactly one child");
		auto child = children[0];
		child.arrange(adjustHint(rw, paramsX), adjustHint(rh, paramsY));
		this.w = adjustSize(child.w, rw, paramsX);
		this.h = adjustSize(child.h, rh, paramsY);
		child.x = adjustPos(child.x, child.w, rw, paramsX);
		child.y = adjustPos(child.y, child.h, rh, paramsY);
	}

	private Params paramsX, paramsY;
	static if (Params.length)
		this(Params paramsX, Params paramsY)
		{
			this.paramsX = paramsX;
			this.paramsY = paramsY;
		}

	/// Declares adjustHint, adjustSize, adjustPos
	mixin ComplementWrapperBehavior!(WrapperBehavior, Params);
}

mixin template DeclareWrapper(string name, alias WrapperBehavior, Params...)
{
	mixin(`alias WCustomWrapper!(WrapperBehavior, Params) W`~name~`;`);
	mixin(`alias HCustomWrapper!(WrapperBehavior, Params) H`~name~`;`);
	mixin(`alias  CustomWrapper!(WrapperBehavior, Params)  `~name~`;`);
}

private mixin template SizeBehavior()
{
	int adjustHint(int hint, RelativeSize size)
	{
		return size.toPixels(hint);
	}
}
/// Wrapper to override the parent hint to a specific size.
mixin DeclareWrapper!("Size", SizeBehavior, RelativeSize);

private mixin template ShrinkBehavior()
{
	int adjustHint(int hint)
	{
		return 0;
	}
}
/// Wrapper to override the parent hint to 0, thus making
/// the wrapped control as small as it can be.
mixin DeclareWrapper!("Shrink", ShrinkBehavior);

private mixin template CenterBehavior()
{
	int adjustSize(int size, int hint)
	{
		return max(size, hint);
	}

	int adjustPos(int pos, int size, int hint)
	{
		if (hint < size) hint = size;
		return (hint-size)/2;
	}
}
/// If content is smaller than parent hint, center the content and use parent hint for own size.
mixin DeclareWrapper!("Center", CenterBehavior);

private mixin template PadBehavior()
{
	int adjustHint(int hint, RelativeSize padding)
	{
		auto paddingPx = padding.toPixels(hint);
		return max(0, hint - paddingPx*2);
	}

	int adjustSize(int size, int hint, RelativeSize padding)
	{
		auto paddingPx = padding.toPixels(hint);
		return size + paddingPx*2;
	}

	int adjustPos(int pos, int size, int hint, RelativeSize padding)
	{
		auto paddingPx = padding.toPixels(hint);
		return paddingPx;
	}
}
/// Add some padding on both sides of the content.
mixin DeclareWrapper!("Pad", PadBehavior, RelativeSize);

// ***************************************************************************

/// Space out controls in a 2D grid, according to their dimensions and resizability.
class Table : ContainerControl
{
	uint rows, cols;

	this(uint rows, uint cols)
	{
		this.rows = rows;
		this.cols = cols;
	}

	override void arrange(int rw, int rh)
	{
		assert(children.length == rows*cols, "Wrong number of table children");

		static struct Size { int w, h; }
		Size[][] minSizes = new Size[][](cols, rows);
		int[] minColSizes = new int[cols];
		int[] minRowSizes = new int[rows];

		foreach (i, child; children)
		{
			child.arrange(0, 0);
			auto col = i % cols;
			auto row = i / cols;
			minSizes[row][col] = Size(child.w, child.h);
			minColSizes[col] = max(minColSizes[col], child.w);
			minRowSizes[row] = max(minRowSizes[row], child.h);
		}

		import std.algorithm;
		int minW = reduce!"a + b"(0, minColSizes);
		int minH = reduce!"a + b"(0, minRowSizes);

		// If all controls can take up no space, spread them out equivalently
		if (minW == 0) { minW = cols; minColSizes[] = 1; }
		if (minH == 0) { minH = rows; minRowSizes[] = 1; }

		// TODO: fixed-size rows / columns
		// Maybe associate RelativeSize values with rows/columns?

		this.w = max(minW, rw);
		this.h = max(minH, rh);

		int[] colSizes = new int[cols];
		int[] colOffsets = new int[cols];
		int p = 0;
		foreach (col; 0..cols)
		{
			colOffsets[col] = p;
			auto size = minW ? minColSizes[col] * this.w / minW : 0;
			colSizes[col] = size;
			p += size;
		}

		int[] rowSizes = new int[rows];
		int[] rowOffsets = new int[rows];
		p = 0;
		foreach (row; 0..rows)
		{
			rowOffsets[row] = p;
			auto size = minH ? minRowSizes[row] * this.h / minH : 0;
			rowSizes[row] = size;
			p += size;
		}

		foreach (i, child; children)
		{
			auto col = i % cols;
			auto row = i / cols;
			child.x = colOffsets[col];
			child.y = rowOffsets[row];
			child.arrange(colSizes[col], rowSizes[col]);
		}
	}
}

/// 1D table for a row of controls.
class Row : Table
{
	this() { super(0, 0); }

	override void arrange(int rw, int rh)
	{
		rows = 1;
		cols = cast(uint)children.length;
		super.arrange(rw, rh);
	}
}

/// 1D table for a column of controls.
class Column : Table
{
	this() { super(0, 0); }

	override void arrange(int rw, int rh)
	{
		rows = cast(uint)children.length;
		cols = 1;
		super.arrange(rw, rh);
	}
}

// ***************************************************************************

/// All children occupy the entire area of the control.
/// The control grows as necessary to accommodate all layers.
class Layers : ContainerControl
{
	override void arrange(int rw, int rh)
	{
		w = rw; h = rh;
		bool changed;
		do
		{
			changed = false;
			foreach (child; children)
			{
				child.arrange(w, h);
				if (child.w > w)
					w = child.w, changed = true;
				if (child.h > h)
					h = child.h, changed = true;
			}
		} while (changed);
	}
}

// ***************************************************************************

/// Container for all top-level windows.
/// The root control's children are, semantically, layers.
final class RootControl : ContainerControl
{
	override void arrange(int rw, int rh)
	{
		foreach (child; children)
			child.arrange(w, h);
	}

	// Expose "arrange", which is "protected", to WMApplication
	final void sizeChanged()
	{
		arrange(w, h);
	}
}
