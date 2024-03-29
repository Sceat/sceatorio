require("src.utils.msg")

EVOLUTION_PER_MINUTE = 0.00005
EVOLUTION_PER_WORM_KILL = 0.001
EVOLUTION_PER_NEST_KILL = 0.007

function evolveTeamEnemies(force)
  local biter_nest_kill = force.kill_count_statistics.get_flow_count{name="biter-spawner", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local spitter_nest_kill = force.kill_count_statistics.get_flow_count{name="spitter-spawner", input="input_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local behemoth_worm_turret_kill = force.kill_count_statistics.get_flow_count{name="behemoth-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local big_worm_turret_kill = force.kill_count_statistics.get_flow_count{name="big-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local medium_worm_turret_kill = force.kill_count_statistics.get_flow_count{name="medium-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}
  local small_worm_turret_kill = force.kill_count_statistics.get_flow_count{name="small-worm-turret", input="output_counts", precision_index = defines.flow_precision_index.one_minute, count=true}

  local enemy = game.forces[('enemy='..(force.name))]
  local worm_kills = behemoth_worm_turret_kill + big_worm_turret_kill + medium_worm_turret_kill + small_worm_turret_kill
  local nest_kills = biter_nest_kill + spitter_nest_kill

  enemy.evolution_factor_by_time = enemy.evolution_factor_by_time+EVOLUTION_PER_MINUTE
  enemy.evolution_factor_by_pollution = enemy.evolution_factor_by_pollution+(worm_kills*EVOLUTION_PER_WORM_KILL)
  enemy.evolution_factor_by_killing_spawners = enemy.evolution_factor_by_killing_spawners+(nest_kills*EVOLUTION_PER_NEST_KILL)
  enemy.evolution_factor = 1 - (1 - enemy.evolution_factor_by_time) * (1 - enemy.evolution_factor_by_pollution) * (1 - enemy.evolution_factor_by_killing_spawners)
end
