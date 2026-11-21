defmodule Mythweaver.Attachments.ProxyTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Attachments.Proxy
  alias Mythweaver.Attachments.Proxy.Cloudflare
  alias Mythweaver.Attachments.Proxy.Fastly
  alias Mythweaver.Attachments.Proxy.Xtandard

  @key "736563726574"
  @salt "68656C6C6F"
  @enc_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

  defp decrypt(token, hex_key, cipher \\ :aes_256_cbc) do
    <<iv::binary-size(16), ciphertext::binary>> = Base.url_decode64!(token, padding: false)
    padded = :crypto.crypto_one_time(cipher, Base.decode16!(hex_key, case: :mixed), iv, ciphertext, false)
    binary_part(padded, 0, byte_size(padded) - :binary.last(padded))
  end

  # Splits `<base>/<signature><path>` into the signature and the signed path.
  defp signed_parts(url, base) do
    [signature, rest] = url |> String.replace_prefix(base, "") |> String.split("/", parts: 2)
    {signature, "/" <> rest}
  end

  describe "Xtandard" do
    test "signs paths with the URL dialect's documented test vector" do
      path = "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png"
      assert Xtandard.sign(path, @key, @salt) == "oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8"
    end

    test "fetches source_prefix <> key, encrypted, and signs the expiry with the rest of the path" do
      build = fn ->
        Xtandard.url(
          "/uploads/attachments/x.png?exp=1&sig=s",
          "attachments/x.png",
          Proxy.preset!(:avatar),
          1_700_000_000,
          base_url: "http://img:8080",
          source_prefix: "xi://uploads/",
          key: @key,
          salt: @salt,
          encryption_key: @enc_key
        )
      end

      url = build.()
      {signature, path} = signed_parts(url, "http://img:8080/")
      assert signature == Xtandard.sign(path, @key, @salt)
      assert "/rs:fill-down:96:96:0/g:sm/exp:1700000000/enc/" <> token = path
      assert decrypt(token, @enc_key) == "xi://uploads/attachments/x.png"
      # A deterministic IV: the same source gives the same URL, so caches can hold it.
      assert build.() == url
    end

    test "a width-only box fits the width and lets the height follow" do
      url =
        Xtandard.url("http://s/x.png", "x.png", Proxy.preset!(:inline), 1,
          base_url: "http://img",
          key: @key,
          salt: @salt,
          encryption_key: @enc_key
        )

      assert url =~ "/rs:fit:960:0:0/"
    end

    test "info_url/5 signs the options path, not the /info prefix" do
      url =
        Xtandard.info_url("http://s/x.png", "x.png", "bh:4:3", 1_700_000_000,
          base_url: "http://img:8080/",
          key: @key,
          salt: @salt,
          encryption_key: @enc_key
        )

      {signature, path} = signed_parts(url, "http://img:8080/info/")
      assert String.starts_with?(url, "http://img:8080/info/")
      assert signature == Xtandard.sign(path, @key, @salt)
      assert "/bh:4:3/exp:1700000000/enc/" <> token = path
      assert decrypt(token, @enc_key) == "http://s/x.png"
    end

    test "original_url/4 asks for the raw bytes under the same signature, expiry and encrypted source" do
      url =
        Xtandard.original_url("/uploads/attachments/x.png?exp=1&sig=s", "attachments/x.png", 1_700_000_000,
          base_url: "http://img:8080",
          source_prefix: "xi://uploads/",
          key: @key,
          salt: @salt,
          encryption_key: @enc_key
        )

      {signature, path} = signed_parts(url, "http://img:8080/")
      assert signature == Xtandard.sign(path, @key, @salt)
      assert "/raw:1/exp:1700000000/enc/" <> token = path
      assert decrypt(token, @enc_key) == "xi://uploads/attachments/x.png"
    end

    test "a 16-byte encryption key encrypts with AES-128" do
      key = "000102030405060708090a0b0c0d0e0f"
      assert decrypt(Xtandard.encrypt("xi://uploads/a.png", key), key, :aes_128_cbc) == "xi://uploads/a.png"
    end
  end

  # Vectors from the official clients' shared fixture:
  # https://github.com/xantiagoma/xtandard-image/blob/v0.1.1/clients/spec/conformance.json
  describe "Xtandard upstream conformance vectors" do
    @spec_key "943b421c9eb07c830af81030552c86009268de4e532ba2ee2eab8247c6da0881"
    @spec_salt "520f986b998545b4785e0defbc4f3c1203f22de2374a3d53cb7a7fe9fea309c5"
    @spec_enc_key "1eb5b0e971ad7f45324c1bb15c947cb207c43152fa5c6c7f35c4f36e0c18e0f1"
    @spec_iv "30313233343536373839616263646566"
    @cat_token "MDEyMzQ1Njc4OWFiY2RlZlCnHoxM-FYigjog_TOOb0Ju_RiyysDwGaswBgh_dPfEc7CjMZ_rE2sIEoIYZ0lwsw"

    defp seal(src),
      do: Xtandard.seal(src, Base.decode16!(@spec_enc_key, case: :mixed), Base.decode16!(@spec_iv, case: :mixed))

    test "sign_examples_vector" do
      assert Xtandard.sign("/rs:fit:300:300/plain/http://img.example.com/pretty/image.jpg", @spec_key, @spec_salt) ==
               "m3k5QADfcKPDj-SDI2AIogZbC3FlAXszuwhtWXYqavc"
    end

    test "encrypt_source" do
      assert seal("https://example.com/images/cat.jpg") == @cat_token
    end

    test "encrypt_source_unicode" do
      assert seal("local:///fotos/año/ñandú.jpg") ==
               "MDEyMzQ1Njc4OWFiY2RlZtnI76ymo9nwZVJBKvczSqqN_XpOg9YJ-0bCc3mNkDai"
    end

    test "encrypted_deterministic: the signature covers the path after it, /enc/ included" do
      assert Xtandard.sign("/w:640/enc/#{@cat_token}.jpg", @spec_key, @spec_salt) ==
               "poegq-tPx616BI9d2cG3_8aZ8Q2RSdDRMZFBzaNAEJM"
    end

    test "info_encrypted: an /info signature excludes the /info prefix" do
      assert Xtandard.sign("/pn:1/enc/#{@cat_token}", @spec_key, @spec_salt) ==
               "2GYLybCytthEg4GT99uenMPhi_QOere9OJQqb2YvhwY"
    end
  end

  test "Cloudflare contain scales down the signed source" do
    assert Cloudflare.url("/uploads/x.png?exp=1&sig=s", "x.png", {320, 320, :contain}, 1, zone_url: "https://zone") ==
             "https://zone/cdn-cgi/image/width=320,height=320,fit=scale-down,format=auto//uploads/x.png?exp=1&sig=s"
  end

  test "Cloudflare and Fastly bound only the width of a width-only box" do
    assert Cloudflare.url("/x.png", "x.png", {960, nil, :contain}, 1, zone_url: "https://zone") ==
             "https://zone/cdn-cgi/image/width=960,fit=scale-down,format=auto//x.png"

    assert Fastly.url("/x.png", "x.png", {960, nil, :contain}, 1, []) == "/x.png?width=960&fit=bounds&auto=webp"
  end

  describe "Fastly" do
    test "appends its parameters to a signed source's query" do
      assert Fastly.url("/uploads/x.png?exp=1&sig=s", "x.png", {96, 96, :cover}, 1, []) ==
               "/uploads/x.png?exp=1&sig=s&width=96&height=96&fit=crop&auto=webp"
    end

    test "with base_url, addresses the key on the Fastly service" do
      assert Fastly.url("https://s3/x.png?X-Amz-Signature=s", "x.png", {96, 96, :cover}, 1, base_url: "https://cdn/") ==
               "https://cdn/x.png?width=96&height=96&fit=crop&auto=webp"
    end

    test "re-encodes to PNG without resizing" do
      assert Fastly.png_url("/uploads/x.jpg?exp=1&sig=s", "x.jpg", 1, []) == "/uploads/x.jpg?exp=1&sig=s&format=png"

      assert Fastly.png_url("https://s3/x.jpg?sig=s", "x.jpg", 1, base_url: "https://cdn") ==
               "https://cdn/x.jpg?format=png"
    end
  end

  test "unknown presets raise" do
    assert_raise ArgumentError, fn -> Proxy.preset!(:huge) end
  end
end
