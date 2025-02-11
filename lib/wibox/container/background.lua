---------------------------------------------------------------------------
-- A container capable of changing the background color, foreground color and
-- widget shape.
--
--@DOC_wibox_container_defaults_background_EXAMPLE@
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @containermod wibox.container.background
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local color = require("gears.color")
local surface = require("gears.surface")
local beautiful = require("beautiful")
local cairo = require("lgi").cairo
local gtable = require("gears.table")
local gshape = require("gears.shape")
local gdebug = require("gears.debug")
local setmetatable = setmetatable
local type = type
local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)

local background = { mt = {} }

-- The Cairo SVG backend doesn't support surface as patterns correctly.
-- The result is both glitchy and blocky. It is also impossible to introspect.
-- Calling this function replace the normal code path is a "less correct", but
-- more widely compatible version.
function background._use_fallback_algorithm()
    background.before_draw_children = function(self, _, cr, width, height)
        local bw    = self._private.shape_border_width or 0
        local shape = self._private.shape or gshape.rectangle

        if bw > 0 then
            cr:translate(bw, bw)
            width, height = width - 2*bw, height - 2*bw
        end

        shape(cr, width, height)

        if self._private.background then
            cr:save() --Save to avoid messing with the original source
            cr:set_source(self._private.background)
            cr:fill_preserve()
            cr:restore()
        end

        cr:translate(-bw, -bw)
        cr:clip()

        if self._private.foreground then
            cr:set_source(self._private.foreground)
        end
    end

    background.after_draw_children = function(self, _, cr, width, height)
        local bw    = self._private.shape_border_width or 0
        local shape = self._private.shape or gshape.rectangle

        if bw > 0 then
            cr:save()
            cr:reset_clip()

            local mat = cr:get_matrix()

            -- Prevent the inner part of the border from being written.
            local mask = cairo.RecordingSurface(cairo.Content.COLOR_ALPHA,
                cairo.Rectangle { x = 0, y = 0, width = mat.x0 + width, height = mat.y0 + height })

            local mask_cr = cairo.Context(mask)
            mask_cr:translate(mat.x0, mat.y0)

            -- Clear the surface.
            mask_cr:set_operator(cairo.Operator.CLEAR)
            mask_cr:set_source_rgba(0, 1, 0, 0)
            mask_cr:paint()

            -- Paint the inner and outer borders.
            mask_cr:set_operator(cairo.Operator.SOURCE)
            mask_cr:translate(bw, bw)
            mask_cr:set_source_rgba(1, 0, 0, 1)
            mask_cr:set_line_width(2*bw)
            shape(mask_cr, width - 2*bw, height - 2*bw)
            mask_cr:stroke_preserve()

            -- Remove the inner part.
            mask_cr:set_source_rgba(0, 1, 0, 0)
            mask_cr:set_operator(cairo.Operator.CLEAR)
            mask_cr:fill()
            mask:flush()

            cr:set_source(color(self._private.shape_border_color or self._private.foreground or beautiful.fg_normal))
            cr:mask_surface(mask, 0,0)
            cr:restore()
        end
    end
end

-- Make sure a surface pattern is freed *now*
local function dispose_pattern(pattern)
    local status, s = pattern:get_surface()
    if status == "SUCCESS" then
        s:finish()
    end
end

-- Prepare drawing the children of this widget
function background:before_draw_children(context, cr, width, height)
    local bw    = self._private.shape_border_width or 0
    local shape = self._private.shape or (bw > 0 and gshape.rectangle or nil)

    -- Redirect drawing to a temporary surface if there is a shape
    if shape then
        cr:push_group_with_content(cairo.Content.COLOR_ALPHA)
    end

    -- Draw the background
    if self._private.background then
        cr:save()
        cr:set_source(self._private.background)
        cr:rectangle(0, 0, width, height)
        cr:fill()
        cr:restore()
    end
    if self._private.bgimage then
        cr:save()
        if type(self._private.bgimage) == "function" then
            self._private.bgimage(context, cr, width, height,unpack(self._private.bgimage_args))
        else
            local pattern = cairo.Pattern.create_for_surface(self._private.bgimage)
            cr:set_source(pattern)
            cr:rectangle(0, 0, width, height)
            cr:fill()
        end
        cr:restore()
    end

    if self._private.foreground then
        cr:set_source(self._private.foreground)
    end
end

-- Draw the border
function background:after_draw_children(_, cr, width, height)
    local bw    = self._private.shape_border_width or 0
    local shape = self._private.shape or (bw > 0 and gshape.rectangle or nil)

    if not shape then
        return
    end

    -- Okay, there is a shape. Get it as a path.

    cr:translate(bw, bw)
    shape(cr, width - 2*bw, height - 2*bw, unpack(self._private.shape_args or {}))
    cr:translate(-bw, -bw)

    if bw > 0 then
        -- Now we need to do a border, somehow. We begin with another
        -- temporary surface.
        cr:push_group_with_content(cairo.Content.ALPHA)

        -- Mark everything as "this is border"
        cr:set_source_rgba(0, 0, 0, 1)
        cr:paint()

        -- Now remove the inside of the shape to get just the border
        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(0, 0, 0, 0)
        cr:fill_preserve()

        local mask = cr:pop_group()
        -- Now actually draw the border via the mask we just created.
        cr:set_source(color(self._private.shape_border_color or self._private.foreground or beautiful.fg_normal))
        cr:set_operator(cairo.Operator.SOURCE)
        cr:mask(mask)

        dispose_pattern(mask)
    end

    -- We now have the right content in a temporary surface. Copy it to the
    -- target surface. For this, we need another mask
    cr:push_group_with_content(cairo.Content.ALPHA)

    -- Draw the border with 2 * border width (this draws both
    -- inside and outside, only half of it is outside)
    cr.line_width = 2 * bw
    cr:set_source_rgba(0, 0, 0, 1)
    cr:stroke_preserve()

    -- Now fill the whole inside so that it is also include in the mask
    cr:fill()

    local mask = cr:pop_group()
    local source = cr:pop_group() -- This pops what was pushed in before_draw_children

    -- This now draws the content of the background widget to the actual
    -- target, but only the part that is inside the mask
    cr:set_operator(cairo.Operator.OVER)
    cr:set_source(source)
    cr:mask(mask)

    dispose_pattern(mask)
    dispose_pattern(source)
end

-- Layout this widget
function background:layout(_, width, height)
    if self._private.widget then
        local bw = self._private.border_strategy == "inner" and
            self._private.shape_border_width or 0

        return { base.place_widget_at(
            self._private.widget, bw, bw, width-2*bw, height-2*bw
        ) }
    end
end

-- Fit this widget into the given area
function background:fit(context, width, height)
    if not self._private.widget then
        return 0, 0
    end

    local bw = self._private.border_strategy == "inner" and
        self._private.shape_border_width or 0

    local w, h = base.fit_widget(
        self, context, self._private.widget, width - 2*bw, height - 2*bw
    )

    return w+2*bw, h+2*bw
end

--- The widget displayed in the background widget.
-- @property widget
-- @tparam widget widget The widget to be disaplayed inside of the background
--  area.
-- @interface container

background.set_widget = base.set_widget_common

function background:get_widget()
    return self._private.widget
end

function background:get_children()
    return {self._private.widget}
end

function background:set_children(children)
    self:set_widget(children[1])
end

--- The background color/pattern/gradient to use.
--
--@DOC_wibox_container_background_bg_EXAMPLE@
--
-- @property bg
-- @tparam color bg A color string, pattern or gradient
-- @see gears.color
-- @propemits true false

function background:set_bg(bg)
    if bg then
        self._private.background = color(bg)
    else
        self._private.background = nil
    end
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::bg", bg)
end

function background:get_bg()
    return self._private.background
end

--- The foreground (text) color/pattern/gradient to use.
--
--@DOC_wibox_container_background_fg_EXAMPLE@
--
-- @property fg
-- @tparam color fg A color string, pattern or gradient
-- @propemits true false
-- @see gears.color

function background:set_fg(fg)
    if fg then
        self._private.foreground = color(fg)
    else
        self._private.foreground = nil
    end
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::fg", fg)
end

function background:get_fg()
    return self._private.foreground
end

--- The background shape.
--
-- Use `set_shape` to set additional shape paramaters.
--
--@DOC_wibox_container_background_shape_EXAMPLE@
--
-- @property shape
-- @tparam gears.shape|function shape A function taking a context, width and height as arguments
-- @see gears.shape
-- @see set_shape

--- Set the background shape.
--
-- Any other arguments will be passed to the shape function.
--
-- @method set_shape
-- @tparam gears.shape|function shape A function taking a context, width and height as arguments
-- @propemits true false
-- @see gears.shape
-- @see shape
function background:set_shape(shape, ...)
    local args = {...}

    if shape == self._private.shape and #args == 0 then return end

    self._private.shape = shape
    self._private.shape_args = {...}
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::shape", shape)
end

function background:get_shape()
    return self._private.shape
end

--- When a `shape` is set, also draw a border.
--
-- See `wibox.container.background.shape` for an usage example.
--
-- @deprecatedproperty shape_border_width
-- @tparam number width The border width
-- @renamedin 4.4 border_width
-- @see border_width

--- Add a border of a specific width.
--
-- If the shape is set, the border will also be shaped.
--
-- See `wibox.container.background.shape` for an usage example.
-- @property border_width
-- @tparam[opt=0] number width The border width.
-- @propemits true false
-- @introducedin 4.4
-- @see border_color

function background:set_border_width(width)
    if self._private.shape_border_width == width then return end

    self._private.shape_border_width = width
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::border_width", width)
end

function background:get_border_width()
    return self._private.shape_border_width
end

function background.get_shape_border_width(...)
    gdebug.deprecate("Use `border_width` instead of `shape_border_width`",
        {deprecated_in=5})

    return background.get_border_width(...)
end

function background.set_shape_border_width(...)
    gdebug.deprecate("Use `border_width` instead of `shape_border_width`",
        {deprecated_in=5})

    background.set_border_width(...)
end

--- When a `shape` is set, also draw a border.
--
-- See `wibox.container.background.shape` for an usage example.
--
-- @deprecatedproperty shape_border_color
-- @usebeautiful beautiful.fg_normal Fallback when 'fg' and `border_color` aren't set.
-- @tparam[opt=self._private.foreground] color fg The border color, pattern or gradient
-- @renamedin 4.4 border_color
-- @see gears.color
-- @see border_color

--- Set the color for the border.
--
-- See `wibox.container.background.shape` for an usage example.
-- @property border_color
-- @tparam[opt=self._private.foreground] color fg The border color, pattern or gradient
-- @propemits true false
-- @usebeautiful beautiful.fg_normal Fallback when 'fg' and `border_color` aren't set.
-- @introducedin 4.4
-- @see gears.color
-- @see border_width

function background:set_border_color(fg)
    if self._private.shape_border_color == fg then return end

    self._private.shape_border_color = fg
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::border_color", fg)
end

function background:get_border_color()
    return self._private.shape_border_color
end

function background.get_shape_border_color(...)
    gdebug.deprecate("Use `border_color` instead of `shape_border_color`",
        {deprecated_in=5})

    return background.get_border_color(...)
end

function background.set_shape_border_color(...)
    gdebug.deprecate("Use `border_color` instead of `shape_border_color`",
        {deprecated_in=5})

    background.set_border_color(...)
end

function background:set_shape_clip(value)
    if value then return end
    require("gears.debug").print_warning("shape_clip property of background container was removed."
        .. " Use wibox.layout.stack instead if you want shape_clip=false.")
end

function background:get_shape_clip()
    require("gears.debug").print_warning("shape_clip property of background container was removed."
        .. " Use wibox.layout.stack instead if you want shape_clip=false.")
    return true
end

--- How the border width affects the contained widget.
--
-- The valid values are:
--
-- * *none*: Just apply the border, do not affect the content size (default).
-- * *inner*: Squeeze the size of the content by the border width.
--
-- @property border_strategy
-- @tparam[opt="none"] string border_strategy

function background:set_border_strategy(value)
    self._private.border_strategy = value
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::border_strategy", value)
end

--- The background image to use.
--
-- If `image` is a function, it will be called with `(context, cr, width, height)`
-- as arguments. Any other arguments passed to this method will be appended.
--
-- @property bgimage
-- @tparam string|surface|function image A background image or a function
-- @see gears.surface

function background:set_bgimage(image, ...)
    self._private.bgimage = type(image) == "function" and image or surface.load(image)
    self._private.bgimage_args = {...}
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::bgimage", image)
end

function background:get_bgimage()
    return self._private.bgimage
end

--- Returns a new background container.
--
-- A background container applies a background and foreground color
-- to another widget.
--
-- @tparam[opt] widget widget The widget to display.
-- @tparam[opt] color bg The background to use for that widget.
-- @tparam[opt] gears.shape|function shape A `gears.shape` compatible shape function
-- @constructorfct wibox.container.background
local function new(widget, bg, shape)
    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    gtable.crush(ret, background, true)

    ret._private.shape = shape

    ret:set_widget(widget)
    ret:set_bg(bg)

    return ret
end

function background.mt:__call(...)
    return new(...)
end

return setmetatable(background, background.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
