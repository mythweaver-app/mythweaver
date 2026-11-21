alias Mythweaver.Prompts

# Built-in content for a new install: no characters, chats, connections or lore. Dev test data:
# `priv/repo/dev_seeds.exs`.
Code.require_file("seeds/scope.exs", __DIR__)
seed_scope = Mythweaver.Seeds.scope()

# Prompts (priv/repo/seeds/prompts.exs): the Default Roleplay prompt, bound globally
Code.require_file("seeds/prompts.exs", __DIR__)

# Memory Books (priv/repo/seeds/memory.exs): memory prompts, the Default profile, a side prompt
Code.require_file("seeds/memory.exs", __DIR__)

# Caption prompts (priv/repo/seeds/captions.exs), assignable to vision models
Code.require_file("seeds/captions.exs", __DIR__)

# The "Default +" expression rule profile (priv/repo/seeds/expressions.exs)
Code.require_file("seeds/expressions.exs", __DIR__)

blocks = length(Prompts.list_blocks(seed_scope))
captions = length(Prompts.list_prompts(seed_scope, :caption))
memory = length(Prompts.list_prompts(seed_scope)) - 1 - captions

IO.puts("""
Seed data successfully populated!

  #{blocks} prompt blocks, 1 roleplay prompt (Default Roleplay), #{memory} memory prompts, #{captions} caption prompts, 1 custom outlet (post_history)
""")
