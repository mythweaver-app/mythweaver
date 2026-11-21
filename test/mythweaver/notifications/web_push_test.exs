defmodule Mythweaver.Notifications.WebPushTest do
  # Sets the global VAPID config.
  use ExUnit.Case, async: false

  alias Mythweaver.Notifications.WebPush

  @endpoint "https://push.example.net/send/abc"

  setup do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    encode = &Base.url_encode64(&1, padding: false)

    Application.put_env(:web_push_ex, :vapid,
      public_key: encode.(public),
      private_key: encode.(private),
      subject: "mailto:admin@example.com"
    )

    on_exit(fn -> Application.delete_env(:web_push_ex, :vapid) end)

    {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      vapid_public: encode.(public),
      subscription: %{endpoint: @endpoint, p256dh: encode.(ua_public), auth: encode.(:crypto.strong_rand_bytes(16))}
    }
  end

  # Guards the dependency: RFC 8291 Appendix A, byte for byte.
  test "encrypts the RFC 8291 example message" do
    decode = &Base.url_decode64!(&1, padding: false)

    subscription = %WebPushEx.Subscription{
      endpoint: URI.parse(@endpoint),
      keys: %{
        p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
        auth: "BTBZMqHH6r4Tts7J_aSIgg"
      }
    }

    body =
      WebPushEx.encrypt_payload("When I grow up, I want to be a watermelon", subscription,
        salt: decode.("DGv6ra1nlYgDCS1FRnbzlw"),
        as_key_pair:
          {decode.("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"),
           decode.("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")}
      )

    assert Base.url_encode64(body, padding: false) ==
             "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
  end

  test "configured? needs every VAPID value" do
    assert WebPush.configured?()

    Application.put_env(:web_push_ex, :vapid, Keyword.put(Application.get_env(:web_push_ex, :vapid), :subject, ""))
    refute WebPush.configured?()
    assert WebPush.public_key() == nil

    Application.delete_env(:web_push_ex, :vapid)
    refute WebPush.configured?()
  end

  test "posts an encrypted, VAPID-signed message with our delivery headers", ctx do
    test = self()

    Req.Test.stub(WebPush, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.request_path, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, 201, "")
    end)

    assert :ok = WebPush.push(ctx.subscription, %{title: "Hi"}, ttl: 120, urgency: :high, topic: "r123")

    assert_receive {:request, "POST", "/send/abc", headers, body}
    # No `content-encoding`/`content-length` here: Req.Test's plug adapter consumes them (both reach
    # a real socket: `aes128gcm` from `WebPushEx.request/3`, the length from Req).
    assert headers["ttl"] == "120"
    assert headers["urgency"] == "high"
    assert headers["topic"] == "r123"
    assert "vapid t=" <> rest = headers["authorization"]
    assert String.ends_with?(rest, ", k=#{ctx.vapid_public}")
    # The plaintext never goes on the wire.
    refute body =~ "Hi"
  end

  test "defaults to a one-hour TTL, normal urgency and no topic", ctx do
    test = self()

    Req.Test.stub(WebPush, fn conn ->
      send(test, {:headers, Map.new(conn.req_headers)})
      Plug.Conn.send_resp(conn, 201, "")
    end)

    assert :ok = WebPush.push(ctx.subscription, %{})
    assert_receive {:headers, headers}
    assert headers["ttl"] == "3600"
    assert headers["urgency"] == "normal"
    refute Map.has_key?(headers, "topic")
  end

  test "maps the push service's answer", ctx do
    for {status, expected} <- [
          {200, :ok},
          {202, :ok},
          {404, :gone},
          {410, :gone},
          {413, {:error, 413}},
          {429, {:error, 429}}
        ] do
      Req.Test.stub(WebPush, &Plug.Conn.send_resp(&1, status, ""))
      assert WebPush.push(ctx.subscription, %{}) == expected, "status #{status}"
    end
  end

  test "a transport failure is an error, not a retry", ctx do
    test = self()

    Req.Test.stub(WebPush, fn conn ->
      send(test, :attempt)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %Req.TransportError{reason: :econnrefused}} = WebPush.push(ctx.subscription, %{})
    assert_receive :attempt
    refute_receive :attempt, 50
  end
end
