require("src.utils.msg")

EVOLUTION_PER_MINUTE = 0.0001
EVOLUTION_PER_BITER_KILL = 0.001
EVOLUTION_PER_WORM_KILL = 0.005
EVOLUTION_PER_NEST_KILL = 0.01

function evolveTeamEnemies(force)
  local biter_nest_kill = force.kill_count_statistics.get_flow_count{name="biter-spawner", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local spitter_nest_kill = force.kill_count_statistics.get_flow_count{name="spitter-spawner", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local behemoth_biter_kill = force.kill_count_statistics.get_flow_count{name="behemoth-biter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local behemoth_spitter_kill = force.kill_count_statistics.get_flow_count{name="behemoth-spitter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local big_biter_kill = force.kill_count_statistics.get_flow_count{name="big-biter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local big_spitter_kill = force.kill_count_statistics.get_flow_count{name="big-spitter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local medium_biter_kill = force.kill_count_statistics.get_flow_count{name="medium-biter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local medium_spitter_kill = force.kill_count_statistics.get_flow_count{name="medium-spitter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local small_biter_kill = force.kill_count_statistics.get_flow_count{name="small-biter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local small_spitter_kill = force.kill_count_statistics.get_flow_count{name="small-spitter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local medium_spitter_kill = force.kill_count_statistics.get_flow_count{name="medium-spitter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local small_biter_kill = force.kill_count_statistics.get_flow_count{name="small-biter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local small_spitter_kill = force.kill_count_statistics.get_flow_count{name="small-spitter", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local behemoth_worm_turret_kill = force.entity_build_count_statistics.get_flow_count{name="behemoth-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local big_worm_turret_kill = force.entity_build_count_statistics.get_flow_count{name="big-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local medium_worm_turret_kill = force.entity_build_count_statistics.get_flow_count{name="medium-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local small_worm_turret_kill = force.entity_build_count_statistics.get_flow_count{name="small-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}

  local enemy = game.forces[('enemy='..(force.name))]
  local kills = behemoth_biter_kill + behemoth_spitter_kill + big_biter_kill + big_spitter_kill + medium_biter_kill + medium_spitter_kill + small_biter_kill + small_spitter_kill
  local worm_kills = behemoth_worm_turret_kill + big_worm_turret_kill + medium_worm_turret_kill + small_worm_turret_kill
  local nest_kills = biter_nest_kill + spitter_nest_kill

  enemy.evolution_factor_by_time = enemy.evolution_factor_by_time+EVOLUTION_PER_MINUTE
  enemy.evolution_factor_by_pollution = enemy.evolution_factor_by_pollution+(kills*EVOLUTION_PER_BITER_KILL)+(worm_kills*EVOLUTION_PER_WORM_KILL)
  enemy.evolution_factor_by_killing_spawners = enemy.evolution_factor_by_killing_spawners+(nest_kills*EVOLUTION_PER_NEST_KILL)
  enemy.evolution_factor = 1 - (1 - enemy.evolution_factor_by_time) * (1 - enemy.evolution_factor_by_pollution) * (1 - enemy.evolution_factor_by_killing_spawners)
end
