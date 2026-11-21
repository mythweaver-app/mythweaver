import Ecto.Query

alias Mythweaver.Accounts.Scope
alias Mythweaver.Accounts.User
alias Mythweaver.Characters
alias Mythweaver.Chats
alias Mythweaver.Messages
alias Mythweaver.Repo

# Dev seeds: sample data for development and screenshots. Destructive: deletes every chat, message
# and character, then runs the public seeds (`priv/repo/seeds.exs`), then adds a sample cast and
# chat. Run with `mix ecto.setup.dev` (or `mix ecto.reset.dev`), or `mix run priv/repo/dev_seeds.exs`
# on an existing database. AI connections and models are left alone, so your own survive a re-seed.
#
# Order is FK-driven, not alphabetical: messages before chats, participants before characters
# (`chat_participants.character_id` is `on_delete: :restrict`).
Repo.delete_all(Messages.MessageBody)
Repo.delete_all(Messages.Message)
Repo.delete_all(Chats.Participant)
Repo.delete_all(Chats.Chat)
Repo.delete_all(Characters.Character)

Code.require_file("seeds.exs", __DIR__)
seed_scope = Mythweaver.Seeds.scope()

# The crew and one passenger of the Kestrel Drift, a small freighter hauling cargo between frontier
# stations.
character_specs = [
  %{
    name: "Captain Imara Vance",
    pronouns: "she/her",
    talkativeness: 0.6,
    description:
      "Owner-captain of the freighter Kestrel Drift. Pragmatic, dry-humored, and always three payments behind on the ship.",
    appearance: "Late forties, close-cropped grey hair, a patched flight jacket."
  },
  %{
    name: "Teo Okafor",
    pronouns: "he/him",
    talkativeness: 0.7,
    description: "The Kestrel's engineer. Talks to the reactor like a pet and distrusts anything newer than he is.",
    appearance: "Broad-shouldered, grease-stained coveralls, a multitool on every pocket."
  },
  %{
    name: "Wren",
    pronouns: "they/them",
    talkativeness: 0.4,
    description:
      "The ship's navigation AI, housed in an old salvaged core. Precise, curious about humans, prone to literal answers.",
    appearance: "A soft amber light that moves between the bridge consoles."
  },
  %{
    name: "Dr. Sela Marsh",
    pronouns: "she/her",
    talkativeness: 0.5,
    description:
      "A xenobotanist who chartered passage to the outer stations. Polite, secretive about her sealed cargo.",
    appearance: "Thirties, neat field jacket, always carrying a sealed specimen case."
  }
]

[imara, teo, wren, _sela] =
  Enum.map(character_specs, fn attrs ->
    {:ok, character} = Characters.create_character(seed_scope, attrs, site: true)
    character
  end)

# Owned by the oldest account; unowned (adopted by the first account later) when none exists yet.
owner = Repo.one(from u in User, order_by: [asc: u.inserted_at, asc: u.id], limit: 1)

{:ok, chat} =
  Chats.create_chat(Scope.for_user(owner), %{
    name: "Strange Signal",
    player_character_id: imara.id,
    participants: Enum.map([imara, teo, wren], &%{character_id: &1.id})
  })

messages = [
  {wren,
   "*The bridge lights dim to amber.* Captain, I am receiving a repeating signal from the debris field off our port bow. It is not on any registry."},
  {imara, ~s("A distress beacon?" *She sets down her coffee.* "Or someone who wants us to think it is.")},
  {teo,
   "*over the intercom* \"Whatever it is, I'd rather not find out with the port stabilizer held together by tape and optimism.\""},
  {wren,
   "The pattern repeats every forty-one seconds. It is old Coalition encoding. The last ship to use it was decommissioned eighty years ago."},
  {imara, "Eighty years and still shouting. Teo, how long to make the stabilizer something better than optimism?"},
  {teo,
   ~s("Two hours if nothing else breaks. Four if you keep asking." *A clang echoes through the deck.* "Make it five.")},
  {wren,
   "If we hold position, the debris drift brings the source within scanning range in approximately three hours. That would coincide with repairs."},
  {imara,
   ~s("Then we wait, we fix, and we look. Nobody touches anything they can't name." *She glances at the comms panel.* "And nobody tells our passenger yet.")},
  {teo,
   "Our passenger who's been staring at that sealed case of hers since we left Halden Station? Sure. That'll stay quiet."},
  {wren, "For the record, Captain, the signal changed eleven seconds ago. It now includes our ship's name."}
]

Enum.each(messages, fn {author, text} ->
  {:ok, _} =
    Messages.create_message(chat, %{
      author_is_character: true,
      author_character_id: author.id,
      bodies: [%{content: text}]
    })
end)

IO.puts("Dev data: 4 characters, 1 chat (Strange Signal, 10 messages)")
