local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fonts = require("src.fonts")

return {
    load_sans = function()
        local F = Fake.new()
        local d = F.pc.display
        d.setFont(d.FONT_8X12)
        local spec, err = Fonts.load(d, "/app", "sans")
        T.eq(err, nil)
        T.eq(#spec.loaded, 2)
        T.eq(spec.rowH, 14)
        T.eq(spec.code.font, d.FONT_SCIENTIFICA)
        T.eq(spec.code.cw, 6)
        T.eq(spec.code.rowH, 12)
        T.eq(F.fontFiles[spec.font], "/app/fonts/sans.pfn")
        T.eq(F.fontFiles[spec.bold], "/app/fonts/sans-bold.pfn")
        T.eq(spec.adv[("i"):byte()], 3)
        T.eq(spec.boldAdv[("i"):byte()], 4)
        T.eq(d.getFont(), d.FONT_8X12, "font restored")
    end,
    load_system = function()
        local F = Fake.new()
        local d = F.pc.display
        local spec = Fonts.load(d, "/app", "system")
        T.eq(#spec.loaded, 0)
        T.eq(next(F.fontFiles), nil)
        T.eq(spec.font, d.FONT_6X8)
        T.eq(spec.bold, d.FONT_6X8)
        T.eq(spec.rowH, 10)
        T.eq(spec.adv.uniform, 6)
    end,
    unload = function()
        local F = Fake.new()
        local d = F.pc.display
        local spec = Fonts.load(d, "/app", "sans")
        Fonts.unload(d, spec)
        T.eq(next(F.fontFiles), nil)
        T.eq(#spec.loaded, 0)
    end,
    missing_file_falls_back = function()
        local F = Fake.new()
        F.missingFonts["/app/fonts/sans-bold.pfn"] = true
        local spec, err = Fonts.load(F.pc.display, "/app", "sans")
        T.ok(err and err:find("sans-bold", 1, true))
        T.eq(spec.name, "system")
        T.eq(next(F.fontFiles), nil, "the first font was unloaded")
    end,
    choices = function()
        T.same(Fonts.CHOICES, { "sans", "system" })
    end,
}
