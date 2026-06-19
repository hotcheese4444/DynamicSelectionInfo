ReUI.Options.Mods["SelectionInfo"] = {
    showCategories  = ReUI.Options.Opt(true),    -- show category headers
    showMass        = ReUI.Options.Opt(true),    -- Resources: Mass (net rate)
    showEnergy      = ReUI.Options.Opt(true),    -- Resources: Energy (net rate)
    showBuildpower  = ReUI.Options.Opt(true),    -- Buildpower
    showMassUsage   = ReUI.Options.Opt(true),    -- Cost: Mass cost (build cost)
    showEnergyUsage = ReUI.Options.Opt(true),    -- Cost: Energy cost (build cost)
    showMassKilled  = ReUI.Options.Opt(true),    -- Mass killed (veterancy)
    showMassReclaimed = ReUI.Options.Opt(true),  -- Mass reclaimed (engineers)
    showDPS         = ReUI.Options.Opt(false),   -- Combat: DPS (base, static)
    showHP          = ReUI.Options.Opt(false),   -- Combat: HP (current)
    showShield      = ReUI.Options.Opt(false),   -- Combat: Shield (current)
    fontScale       = ReUI.Options.Opt(100),     -- font/panel scale, percent
}

function Main()
    local builder = ReUI.Options.Builder
    local options = ReUI.Options.Mods["SelectionInfo"]
    builder.AddOptions("SelectionInfo", "Selection Info", {
        builder.Filter("Show category names",   options.showCategories,    4),
        builder.Filter("Resources: Mass",       options.showMass,          4),
        builder.Filter("Resources: Energy",     options.showEnergy,        4),
        builder.Filter("Buildpower",            options.showBuildpower,    4),
        builder.Filter("Cost: Mass cost",       options.showMassUsage,     4),
        builder.Filter("Cost: Energy cost",     options.showEnergyUsage,   4),
        builder.Filter("Mass killed",           options.showMassKilled,    4),
        builder.Filter("Mass reclaimed",        options.showMassReclaimed, 4),
        builder.Filter("Combat: DPS",           options.showDPS,           4),
        builder.Filter("Combat: HP",            options.showHP,            4),
        builder.Filter("Combat: Shield",        options.showShield,        4),
        builder.Slider("Font scale (%)", 50, 400, 10, options.fontScale,   4),
    })
end
