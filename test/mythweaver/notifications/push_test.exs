defmodule Mythweaver.Notifications.PushTest do
  # Sets the global VAPID config.
  use Mythweaver.DataCase, async: false

  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Focus
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Notifications.PushSubscription
  alias Mythweaver.Notifications.WebPush
  alias Mythweaver.Settings

  setup do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    encode = &Base.url_encode64(&1, padding: false)

    Application.put_env(:web_push_ex, :vapid,
      public_key: encode.(public),
      private_key: encode.(private),
      subject: "mailto:admin@example.com"
    )

    on_exit(fn -> Application.delete_env(:web_push_ex, :vapid) end)

    # One browser keypair for every subscription here, so a test can decrypt what was pushed.
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    Process.put(:browser, %{public: ua_public, private: ua_private, auth: auth})

    %{scope: scope!()}
  end

  defp subscription(endpoint \\ "https://push.example.net/#{System.unique_integer([:positive])}") do
    %{public: public, auth: auth} = Process.get(:browser)

    %{
      "endpoint" => endpoint,
      "keys" => %{
        "p256dh" => Base.url_encode64(public, padding: false),
        "auth" => Base.url_encode64(auth, padding: false)
      }
    }
  end

  # RFC 8291 §3.4 and RFC 8188, the browser's side: the JSON the push carried.
  defp decrypt(<<salt::binary-16, _rs::32, 65, as_public::binary-65, ciphertext::binary>>) do
    %{public: ua_public, private: ua_private, auth: auth} = Process.get(:browser)
    hmac = &:crypto.mac(:hmac, :sha256, &1, &2)
    expand = fn prk, info, length -> binary_part(hmac.(prk, info <> <<1>>), 0, length) end

    ecdh = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    ikm = expand.(hmac.(auth, ecdh), "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    prk = hmac.(salt, ikm)
    cek = expand.(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = expand.(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    size = byte_size(ciphertext) - 16
    <<sealed::binary-size(^size), tag::binary-16>> = ciphertext
    padded = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, sealed, "", tag, false)
    # The last record ends with the 0x02 delimiter, then zero padding.
    [json | _] = :binary.split(String.trim_trailing(padded, <<0>>), <<2>>, [:trim])
    Jason.decode!(json)
  end

  defp device!(scope, endpoint \\ nil) do
    {:ok, device} =
      Notifications.subscribe_device(
        scope,
        if(endpoint, do: subscription(endpoint), else: subscription()),
        "Chrome on Android"
      )

    device
  end

  defp notification(kind \\ :new_message) do
    %Notification{
      id: Mythweaver.Schema.generate_id(),
      kind: kind,
      title: "Geralt replied — Kaer Morhen",
      body: "Wind's howling.",
      chat_id: Mythweaver.Schema.generate_id()
    }
  end

  # Every push the stub answers is reported to the test as `{:pushed, path, headers, payload}`.
  defp stub_push(status \\ 201) do
    test = self()
    browser = Process.get(:browser)

    Req.Test.stub(WebPush, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Process.put(:browser, browser)
      send(test, {:pushed, conn.request_path, Map.new(conn.req_headers), decrypt(body)})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp await_sends do
    for pid <- Task.Supervisor.children(Notifications.PushSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end
  end

  describe "subscribe_device/3" do
    test "saves the browser's subscription, keys encrypted at rest", %{scope: scope} do
      sub = subscription("https://fcm.googleapis.com/fcm/send/abc")
      assert {:ok, device} = Notifications.subscribe_device(scope, sub, "  Chrome on Android  ")

      assert device.label == "Chrome on Android"
      assert device.p256dh == sub["keys"]["p256dh"]
      assert [%{id: id}] = Notifications.list_devices(scope)
      assert id == device.id

      {:ok, %{rows: [[raw]]}} =
        Repo.query("SELECT p256dh FROM push_subscriptions WHERE endpoint = $1", [sub["endpoint"]])

      refute raw == sub["keys"]["p256dh"]
    end

    test "an endpoint already saved moves to whoever subscribes it again", %{scope: scope} do
      endpoint = "https://push.example.net/shared"
      device!(scope, endpoint)
      other = scope!()

      assert {:ok, moved} = Notifications.subscribe_device(other, subscription(endpoint), "Firefox on Linux")
      assert moved.label == "Firefox on Linux"
      assert Notifications.list_devices(scope) == []
      assert [%{id: id}] = Notifications.list_devices(other)
      assert id == moved.id
    end

    test "refuses endpoints the server should not post to, and keys a browser would not send", %{scope: scope} do
      for endpoint <- [
            "http://push.example.net/x",
            "https://localhost/x",
            "https://127.0.0.1/x",
            "https://[::1]/x",
            "https://10.0.0.5/x",
            "not a url"
          ] do
        assert {:error, changeset} = Notifications.subscribe_device(scope, subscription(endpoint), "x")
        assert %{endpoint: [_]} = errors_on(changeset), endpoint
      end

      bad_keys = put_in(subscription(), ["keys", "p256dh"], Base.url_encode64("short", padding: false))
      assert {:error, changeset} = Notifications.subscribe_device(scope, bad_keys, "x")
      assert %{p256dh: [_]} = errors_on(changeset)

      bad_auth = put_in(subscription(), ["keys", "auth"], "!!not base64!!")
      assert {:error, changeset} = Notifications.subscribe_device(scope, bad_auth, "x")
      assert %{auth: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Notifications.subscribe_device(scope, %{"endpoint" => "https://a.example/x", "keys" => "x"}, "x")

      assert %{p256dh: [_], auth: [_]} = errors_on(changeset)
    end

    test "keeps the 10 most recently used devices: an 11th drops the least recently used", %{scope: scope} do
      devices = for _ <- 1..10, do: device!(scope)
      [stale | used] = devices

      # Every device but the first has pushed since it subscribed.
      later = DateTime.add(DateTime.utc_now(:second), 60)

      Repo.update_all(from(d in PushSubscription, where: d.id in ^Enum.map(used, & &1.id)),
        set: [last_success_at: later]
      )

      newest = device!(scope)
      ids = scope |> Notifications.list_devices() |> Enum.map(& &1.id)

      assert length(ids) == 10
      assert newest.id in ids
      refute stale.id in ids

      # Re-subscribing a kept device adds none.
      {:ok, _} = Notifications.subscribe_device(scope, subscription(newest.endpoint), "Chrome on Android")
      assert length(Notifications.list_devices(scope)) == 10
    end

    test "another user's devices do not count", %{scope: scope} do
      other = scope!()
      for _ <- 1..10, do: device!(other)
      device!(scope)

      assert length(Notifications.list_devices(other)) == 10
    end
  end

  describe "remove_device/2 and test_device/2" do
    test "act only on the scope user's own devices", %{scope: scope} do
      device = device!(scope)
      other = scope!()

      assert {:error, :not_found} = Notifications.remove_device(other, device.id)
      assert {:error, :not_found} = Notifications.test_device(other, device.id)

      stub_push()
      assert :ok = Notifications.test_device(scope, device.id)
      assert_receive {:pushed, _, _, _}
      assert [%{last_success_at: %DateTime{}}] = Notifications.list_devices(scope)

      assert :ok = Notifications.remove_device(scope, device.id)
      assert Notifications.list_devices(scope) == []
    end
  end

  describe "notify/2 through push" do
    test "pushes the notification to every device, with the reply's TTL, urgency and per-chat topic",
         %{scope: scope} do
      a = device!(scope, "https://push.example.net/a")
      b = device!(scope, "https://push.example.net/b")
      stub_push()
      n = notification()

      assert :ok = Notifications.notify(scope, n)

      for path <- ["/a", "/b"] do
        assert_receive {:pushed, ^path, headers, payload}
        assert headers["ttl"] == "3600"
        assert headers["urgency"] == "high"
        assert headers["topic"] == "r" <> Base.url_encode64(Ecto.UUID.dump!(n.chat_id), padding: false)
        assert byte_size(headers["topic"]) <= 32

        # The id is the in-app popup's tag too, so a hidden tab and the push show one notification.
        assert payload == %{
                 "id" => n.id,
                 "title" => n.title,
                 "body" => n.body,
                 "icon" => "/images/icons/icon-192.png",
                 "path" => "/chats/#{n.chat_id}"
               }
      end

      await_sends()
      assert Enum.all?(Notifications.list_devices(scope), &match?(%DateTime{}, &1.last_success_at))
      assert Enum.sort([a.id, b.id]) == Enum.sort(Enum.map(Notifications.list_devices(scope), & &1.id))
    end

    test "a memory review keeps a day, has its own topic and opens the Reviews tab", %{scope: scope} do
      device!(scope)
      stub_push()
      # A review is stored in the inbox too, so its chat must exist.
      {:ok, geralt} = Mythweaver.Characters.create_character(scope, %{name: "Geralt"})
      {:ok, ciri} = Mythweaver.Characters.create_character(scope, %{name: "Ciri"})
      participants = [%{character_id: geralt.id}, %{character_id: ciri.id}]
      {:ok, chat} = Mythweaver.Chats.create_chat(scope, %{name: "Kaer Morhen", participants: participants})

      n = %{notification(:memory_review) | chat_id: chat.id}

      Notifications.notify(scope, n)

      assert_receive {:pushed, _, headers, payload}
      assert headers["ttl"] == "86400"
      assert headers["urgency"] == "normal"
      assert "m" <> _ = headers["topic"]
      assert payload["path"] == "/chats/#{n.chat_id}/memory?tab=reviews"
      await_sends()
    end

    test "a device the push service no longer knows is deleted; another failure is recorded", %{scope: scope} do
      device!(scope)
      stub_push(410)
      Notifications.notify(scope, notification())
      assert_receive {:pushed, _, _, _}
      await_sends()
      assert Notifications.list_devices(scope) == []

      device!(scope)
      stub_push(429)
      Notifications.notify(scope, notification())
      assert_receive {:pushed, _, _, _}
      await_sends()
      assert [%{last_failure: "The push service answered 429."}] = Notifications.list_devices(scope)
    end

    test "returns before the push service answers", %{scope: scope} do
      device!(scope)
      test = self()

      Req.Test.stub(WebPush, fn conn ->
        send(test, {:waiting, self()})

        receive do
          :answer -> Plug.Conn.send_resp(conn, 201, "")
        end
      end)

      assert :ok = Notifications.notify(scope, notification())
      assert_receive {:waiting, stub}
      send(stub, :answer)
      await_sends()
    end

    test "skips when the kind's push is off, when muted, or while the user has a focused page", %{scope: scope} do
      device!(scope)
      stub_push()

      :ok = Settings.put(scope, :user, "notifications.new_message.push", false)
      Notifications.notify(scope, notification())
      refute_receive {:pushed, _, _, _}, 100

      :ok = Settings.reset(scope, :user, "notifications.new_message.push")
      :ok = Settings.put(scope, :user, "notifications.muted", true)
      Notifications.notify(scope, notification())
      refute_receive {:pushed, _, _, _}, 100

      :ok = Settings.reset(scope, :user, "notifications.muted")
      :ok = Focus.put(scope.user.id, true)
      Notifications.notify(scope, notification())
      refute_receive {:pushed, _, _, _}, 100

      # The same page losing focus lets the next one through.
      :ok = Focus.put(scope.user.id, false)
      Notifications.notify(scope, notification())
      assert_receive {:pushed, _, _, _}
      await_sends()
    end

    test "without VAPID keys nothing is pushed", %{scope: scope} do
      device!(scope)
      stub_push()
      Application.delete_env(:web_push_ex, :vapid)

      assert :ok = Notifications.notify(scope, notification())
      refute_receive {:pushed, _, _, _}, 100
    end

    test "with previews off the push leaves out what was written", %{scope: scope} do
      device!(scope)
      stub_push()
      :ok = Settings.put(scope, :user, "notifications.push_preview", false)
      n = notification()

      Notifications.notify(scope, n)

      assert_receive {:pushed, _, _, payload}
      assert payload["title"] == n.title
      assert payload["body"] == ""
      await_sends()
    end
  end
end
