# test_ideal_shock.rb
#
# $ prep-gas ideal-air.inp ideal-air-gas-model.lua
# $ ruby test_ideal_shock.rb
#
# PJ, 2019-11-28
#
$LOAD_PATH << '~/gdtkinst/lib'
require 'gdtk/gas'

gmodel = GasModel.new('ideal-air-gas-model.lua')
state1 = GasState.new(gmodel)
state1.p = 125.0e3 # Pa
state1.T = 300.0 # K
state1.update_thermo_from_pT()
state1.update_sound_speed()
puts "state1: %s" % state1
puts "normal shock (in ideal gas), given shock speed"
vs = 2414.0
state2 = GasState.new(gmodel)
flow = GasFlow.new(gmodel)
v2, vg = flow.ideal_shock(state1, vs, state2)
puts "v2=%g vg=%g" % [v2, vg]
puts "state2: %s" % [state2]
