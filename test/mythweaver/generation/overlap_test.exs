defmodule Mythweaver.Generation.OverlapTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Generation.Overlap

  @partial "The garage door rolled up. Katy looked at the luxury car approvingly, noting its"

  test "a restart of the message's last line is dropped, keeping what follows" do
    new = "Katy looked at the luxury car approvingly, noting its stylish lines."
    assert Overlap.trim(@partial, new, true) == " stylish lines."
  end

  test "a restart from an earlier sentence, or of a whole finished paragraph, is dropped too" do
    assert Overlap.trim(
             @partial,
             " The garage door rolled up. Katy looked at the luxury car approvingly, noting its curves",
             true
           ) ==
             " curves"

    paragraph = "First.\n\n\"Right, so the party is on Saturday,\" Katy says.\n\n"
    new = "\"Right, so the party is on Saturday,\" Katy says.\n\nPaige nods."
    assert Overlap.trim(paragraph, new, true) == "Paige nods."
  end

  test "a continuation that only shares a word or two with the ending is kept" do
    assert Overlap.trim(@partial, " its stylish lines.", true) == " its stylish lines."
    assert Overlap.trim(@partial, "noting its paint", true) == "noting its paint"
    assert Overlap.trim(@partial, " sleek silhouette.", true) == " sleek silhouette."
  end

  test "mid-stream, text that may still become a restart is held back until it diverges" do
    assert Overlap.trim(@partial, "Katy looked at the", false) == ""
    assert Overlap.trim(@partial, "Katy looked at the garage", false) == "Katy looked at the garage"
    assert Overlap.trim(@partial, " sleek", false) == " sleek"
  end

  test "a reply that stops inside a restart drops it only when it is long enough to count" do
    assert Overlap.trim(@partial, "Katy looked at the luxury", true) == ""
    assert Overlap.trim(@partial, "Katy looked", true) == "Katy looked"
  end
end
