# Seed the built-in expression rule profile, "Default +", and make it the site's default profile
# (`expressions.default_profile`) when none is set.
#
# Rule set from expressions-plus by Tyranomaster (AGPL-3.0), built-in-profiles/default-plus.json.
#
# Runnable on its own (`mix run priv/repo/seeds/expressions.exs`) and required by
# `priv/repo/seeds.exs`. Idempotent: the profile is upserted by name and its rules replaced.

import Ecto.Query

alias Mythweaver.Expressions
alias Mythweaver.Expressions.Profile
alias Mythweaver.Repo
alias Mythweaver.Settings

Code.require_file("scope.exs", __DIR__)
seed_scope = Mythweaver.Seeds.scope()

rules =
  for {name, labels} <- [
        anxious: ~w(fear nervousness),
        awe: ~w(surprise admiration),
        bewildered: ~w(confusion surprise),
        contempt: ~w(anger disapproval),
        despair: ~w(grief sadness),
        disdain: ~w(disapproval disgust),
        dread: ~w(fear realization),
        elated: ~w(excitement joy),
        exasperated: ~w(anger annoyance),
        exhilaration: ~w(excitement surprise),
        frustrated: ~w(annoyance disappointment),
        fury: ~w(anger excitement),
        horrified: ~w(disgust fear),
        intrigued: ~w(curiosity desire),
        lustful: ~w(desire excitement),
        overwhelmed: ~w(confusion excitement),
        panic: ~w(confusion fear),
        reverence: ~w(admiration gratitude),
        tenderness: ~w(caring love),
        trepidation: ~w(excitement nervousness),
        unsettled: ~w(confusion nervousness),
        wonder: ~w(confusion curiosity)
      ] do
    %{
      "name" => to_string(name),
      "kind" => "combination",
      "max_difference" => 25,
      "enabled" => true,
      "conditions" => Enum.map(labels, &%{"label" => &1})
    }
  end

attrs = %{"name" => "Default +", "rules" => rules}

{:ok, profile} =
  case Repo.one(from(p in Profile, where: is_nil(p.user_id) and p.name == "Default +")) do
    nil -> Expressions.create_profile(seed_scope, attrs, site: true)
    profile -> Expressions.update_profile(seed_scope, profile, attrs)
  end

site_values = Repo.one(from(s in Settings.Setting, where: is_nil(s.user_id), select: s.values)) || %{}

if is_nil(site_values["expressions.default_profile"]) do
  :ok = Settings.put(seed_scope, :site, "expressions.default_profile", profile.id)
end
