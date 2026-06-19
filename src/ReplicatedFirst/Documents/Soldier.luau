--!strict
-- Soldier — a worked SdfDocument: a "little soldier" built as six bake groups
-- (one MeshPart each), Lego-figurine style. Ops within a group blend; groups
-- never blend (hard seams). This is the data form of what used to be a
-- throwaway execute_luau blob — bake it with:
--
--   local SdfDocument = require(game.ReplicatedFirst.SdfDocument)
--   local doc = require(game.ReplicatedFirst.Documents.Soldier)
--   SdfDocument.bake(doc, { origin = Vector3.new(0, 0.15, 0), parent = workspace,
--                           primaryGroup = "Uniform" })
--
-- Demonstrates: per-group material/colour/blend/cell, capsule limbs, boxed
-- torso/boots/gear with `rounding`, a `bevel`ed (hard-chamfer) gun stock/mag,
-- and a `subtract` capsule drilling the gun barrel's muzzle bore.

local V = Vector3.new
local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Gun barrel axis — used to place the muzzle bore co-axially.
local MUZZLE = V(-1.5, 6.7, 2.75)
local STOCK_END = V(1.9, 5.0, 2.95)
local BORE_DIR = (STOCK_END - MUZZLE).Unit

return {
	name = "SdfSoldier",
	defaults = { cell = 0.15, blend = 0.4, triCap = 20000 },
	sun = V(0.5, 0.9, 0.35).Unit,
	groups = {
		{
			name = "Skin",
			material = Enum.Material.SmoothPlastic,
			color = rgb(218, 174, 134),
			blend = 0.5,
			prims = {
				{ shape = "capsule", a = V(0, 8.4, 0), b = V(0, 9.0, 0), radius = 0.85 }, -- neck
				{ shape = "ellipsoid", center = V(0, 9.9, 0.1), semi = V(1.7, 1.85, 1.7) }, -- head
				{ shape = "ellipsoid", center = V(-1.0, 6.0, 2.7), semi = V(0.72, 0.72, 0.72) }, -- L hand
				{ shape = "ellipsoid", center = V(1.2, 5.6, 2.7), semi = V(0.72, 0.72, 0.72) }, -- R hand
			},
		},
		{
			name = "Uniform",
			material = Enum.Material.SmoothPlastic,
			color = rgb(104, 112, 72),
			blend = 0.4,
			prims = {
				{ shape = "ellipsoid", center = V(0, 4.3, 0), semi = V(2.1, 1.3, 1.4) }, -- pelvis
				{ shape = "box", center = V(0, 6.6, 0), semi = V(2.5, 2.3, 1.6), rounding = 0.5 }, -- jacket
				{ shape = "ellipsoid", center = V(-2.6, 8.0, 0), semi = V(1.1, 1.1, 1.1) }, -- L shoulder
				{ shape = "ellipsoid", center = V(2.6, 8.0, 0), semi = V(1.1, 1.1, 1.1) }, -- R shoulder
				{ shape = "capsule", a = V(-2.6, 8.0, 0), b = V(-2.2, 6.2, 1.2), radius = 0.85 }, -- L upper arm
				{ shape = "capsule", a = V(-2.2, 6.2, 1.2), b = V(-1.0, 6.0, 2.6), radius = 0.8 }, -- L forearm
				{ shape = "capsule", a = V(2.6, 8.0, 0), b = V(2.2, 6.2, 1.2), radius = 0.85 }, -- R upper arm
				{ shape = "capsule", a = V(2.2, 6.2, 1.2), b = V(1.2, 5.6, 2.6), radius = 0.8 }, -- R forearm
				{ shape = "capsule", a = V(-1.35, 4.2, 0), b = V(-1.45, 2.0, 0.1), radius = 0.95 }, -- L thigh
				{ shape = "capsule", a = V(-1.45, 2.0, 0.1), b = V(-1.45, 0.85, 0.15), radius = 0.95 }, -- L shin
				{ shape = "capsule", a = V(1.35, 4.2, 0), b = V(1.45, 2.0, 0.1), radius = 0.95 }, -- R thigh
				{ shape = "capsule", a = V(1.45, 2.0, 0.1), b = V(1.45, 0.85, 0.15), radius = 0.95 }, -- R shin
			},
		},
		{
			name = "Helmet",
			material = Enum.Material.Metal,
			color = rgb(78, 86, 54),
			blend = 0.4,
			prims = {
				{ shape = "ellipsoid", center = V(0, 10.55, -0.15), semi = V(2.05, 1.55, 2.05) }, -- dome
				{ shape = "box", center = V(0, 9.85, -0.1), semi = V(2.15, 0.28, 2.2), rounding = 0.18 }, -- brim
			},
		},
		{
			name = "Boots",
			material = Enum.Material.SmoothPlastic,
			color = rgb(38, 38, 42),
			blend = 0.2,
			prims = {
				{ shape = "box", center = V(-1.45, 0.5, 0.55), semi = V(1.1, 0.65, 1.7), rounding = 0.25 },
				{ shape = "box", center = V(1.45, 0.5, 0.55), semi = V(1.1, 0.65, 1.7), rounding = 0.25 },
			},
		},
		{
			name = "Gear",
			material = Enum.Material.SmoothPlastic,
			color = rgb(74, 68, 52),
			blend = 0.4,
			prims = {
				{ shape = "box", center = V(0, 6.9, 1.25), semi = V(2.0, 1.8, 0.5), rounding = 0.3 }, -- front vest
				{ shape = "box", center = V(0, 6.8, -2.1), semi = V(1.7, 1.9, 1.0), rounding = 0.3 }, -- backpack
			},
		},
		{
			name = "Gun",
			material = Enum.Material.Metal,
			color = rgb(54, 54, 62),
			blend = 0.1,
			cell = 0.06, -- fine: a thin barrel wall + bore need a small cell (see docs/06)
			prims = {
				{ shape = "capsule", a = MUZZLE, b = STOCK_END, radius = 0.55 }, -- barrel
				-- muzzle bore. NOTE: a subtract cutter must pass CLEAN THROUGH the
				-- solid — a blind hole ending inside leaves a thin domed cavity the
				-- mesher can't resolve at practical cell sizes (surface seam). So
				-- this runs from outside the muzzle out past the stock end.
				{ shape = "capsule", op = "subtract", a = MUZZLE - BORE_DIR * 0.5, b = STOCK_END + BORE_DIR * 0.6, radius = 0.32 },
				{ shape = "box", center = V(2.05, 4.75, 2.95), semi = V(0.55, 0.85, 0.5), bevel = 0.22 }, -- stock
				{ shape = "box", center = V(0.4, 5.3, 3.0), semi = V(0.34, 0.95, 0.32), bevel = 0.12 }, -- magazine
			},
		},
	},
}
