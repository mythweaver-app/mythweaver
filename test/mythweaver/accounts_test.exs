defmodule Mythweaver.AccountsTest do
  # Not async: tests flip the global `:auto_login` app env.
  use Mythweaver.DataCase

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.Throttle
  alias Mythweaver.Accounts.User
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs.Job

  @password "a long test password"

  defp user!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            email: "user#{n}@example.com",
            handle: "u_" <> String.downcase(Integer.to_string(n, 36)),
            password: @password
          },
          attrs
        )
      )

    user
  end

  defp put_auto_login(value) do
    previous = Application.get_env(:mythweaver, :auto_login)
    Application.put_env(:mythweaver, :auto_login, value)
    on_exit(fn -> Application.put_env(:mythweaver, :auto_login, previous) end)
  end

  # Characters need a site content manager; an unsaved owner keeps `register_first_user/1` seeing no users.
  defp chat!(owner_scope) do
    [a, b] =
      for name <- ["A", "B"] do
        {:ok, c} =
          Characters.create_character(%Scope{user: %User{role: :owner}}, %{
            name: "#{name}-#{System.unique_integer([:positive])}"
          })

        c
      end

    {:ok, chat} = Chats.create_chat(owner_scope, %{participants: [%{character_id: a.id}, %{character_id: b.id}]})
    chat
  end

  describe "register_user/1" do
    test "validates email, password length and confirmation" do
      {:error, changeset} =
        Accounts.register_user(%{email: "no-at-sign", password: "short", password_confirmation: "other"})

      assert %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "rejects an email differing only in case" do
      user!(%{email: "a@x.io"})
      {:error, changeset} = Accounts.register_user(%{email: "A@x.io", password: @password})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "blank nickname is stored as nil" do
      assert %User{nickname: nil} = user!(%{nickname: "   "})
    end

    test "normalizes the handle: trimmed, no leading @, lowercase" do
      assert %User{handle: "bob_1"} = user!(%{handle: "  @Bob_1 "})
    end

    test "rejects a handle differing only in case" do
      user!(%{handle: "taken"})

      {:error, changeset} =
        Accounts.register_user(%{email: "taken@example.com", handle: "TAKEN", password: @password})

      assert "has already been taken" in errors_on(changeset).handle
    end

    test "validates handle length, characters and presence" do
      attrs = %{email: "h@example.com", password: @password}

      {:error, changeset} = Accounts.register_user(Map.put(attrs, :handle, "ab"))
      assert "should be at least 3 character(s)" in errors_on(changeset).handle

      {:error, changeset} = Accounts.register_user(Map.put(attrs, :handle, "bad-handle"))
      assert "may only use letters, numbers and underscores" in errors_on(changeset).handle

      {:error, changeset} = Accounts.register_user(attrs)
      assert "can't be blank" in errors_on(changeset).handle
    end
  end

  test "display_name/1 is the nickname, else @handle" do
    assert User.display_name(user!(%{nickname: nil, handle: "solo"})) == "@solo"
    assert User.display_name(user!(%{nickname: "Ann"})) == "Ann"
  end

  test "get_user_by_email_and_password/2 matches only the right password" do
    user = user!()
    assert %User{id: id} = Accounts.get_user_by_email_and_password(user.email, @password)
    assert id == user.id
    refute Accounts.get_user_by_email_and_password(user.email, "wrong password!")
  end

  test "register_first_user/1 refuses once a user exists" do
    assert {:ok, _} =
             Accounts.register_first_user(%{email: "first@example.com", handle: "first", password: @password})

    assert {:error, :already_set_up} =
             Accounts.register_first_user(%{email: "second@example.com", handle: "second", password: @password})
  end

  test "register_first_user/1 adopts unowned chats" do
    chat = chat!(nil)
    {:ok, user} = Accounts.register_first_user(%{email: "first@example.com", handle: "first", password: @password})

    assert Chats.get_chat(chat.id).user_id == user.id
  end

  describe "auto_login_user/0" do
    test "off: nil, and no row is created" do
      put_auto_login(false)
      refute Accounts.auto_login_user()
      refute Accounts.any_users?()
    end

    test "on with no users creates one passwordless admin and reuses it" do
      put_auto_login(true)
      assert %User{email: "admin@localhost", hashed_password: nil, id: id} = Accounts.auto_login_user()
      assert %User{id: ^id} = Accounts.auto_login_user()
    end

    test "on with two users: nil" do
      put_auto_login(true)
      user!()
      user!()
      refute Accounts.auto_login_user()
      refute Accounts.auto_login_available?()
    end
  end

  describe "update_user_profile/3" do
    test "an email change needs the current password" do
      user = user!()

      {:error, changeset} = Accounts.update_user_profile(user, "wrong password!", %{email: "new@example.com"})
      assert %{current_password: ["is not valid"]} = errors_on(changeset)

      assert {:ok, %User{email: "new@example.com"}} =
               Accounts.update_user_profile(user, @password, %{email: "new@example.com"})
    end

    test "a passwordless user changes email without one" do
      put_auto_login(true)
      user = Accounts.auto_login_user()

      assert {:ok, %User{email: "me@example.com"}} =
               Accounts.update_user_profile(user, nil, %{email: "me@example.com"})
    end
  end

  test "update_user_password/3 expires every session" do
    user = user!()
    token = Accounts.generate_user_session_token(user)

    assert {:ok, {_, [_]}} =
             Accounts.update_user_password(user, @password, %{
               password: "another long password",
               password_confirmation: "another long password"
             })

    refute Accounts.get_user_by_session_token(token)
  end

  test "delete_user/2 returns the user's tokens" do
    user = user!()
    token = Accounts.generate_user_session_token(user)

    assert {:ok, {_, [%{token: ^token}]}} = Accounts.delete_user(scope!(), user)
    refute Accounts.get_user(user.id)
  end

  test "delete_user/2 deletes the user's chats with them" do
    user = user!()
    chat = chat!(Scope.for_user(user))

    {:ok, _} = Accounts.delete_user(scope!(), user)

    refute Chats.get_chat(chat.id)
  end

  test "delete_user/2 deletes a user whose jobs ran on their own model" do
    user = user!()
    {:ok, model} = Mythweaver.AI.create_model(Scope.for_user(user), %{name: "Own", api_model_id: "own"})

    job =
      Repo.insert!(%Job{
        tag: :reply,
        origin: :interactive,
        status: :completed,
        user_id: user.id,
        ai_model_id: model.id,
        label: "Reply"
      })

    assert {:ok, _} = Accounts.delete_user(scope!(), user)
    assert %{user_id: nil, ai_model_id: nil} = Repo.get(Job, job.id)
  end

  test "first-user setup and auto-login create an owner" do
    put_auto_login(true)
    assert %User{role: :owner} = Accounts.auto_login_user()

    Repo.delete_all(User)

    assert {:ok, %User{role: :owner}} =
             Accounts.register_first_user(%{email: "first@example.com", handle: "first", password: @password})
  end

  defp new_user_attrs(role) do
    n = System.unique_integer([:positive])

    %{
      "email" => "new#{n}@example.com",
      "handle" => "new_" <> String.downcase(Integer.to_string(n, 36)),
      "password" => @password,
      "role" => role
    }
  end

  describe "roles" do
    setup do
      %{owner: scope!(%{role: :owner}), admin: scope!(%{role: :admin})}
    end

    test "only an owner creates an owner", %{owner: owner, admin: admin} do
      assert {:error, :unauthorized} = Accounts.create_user(admin, new_user_attrs("owner"))
      assert {:ok, %User{role: :user}} = Accounts.create_user(admin, new_user_attrs("user"))
      assert {:ok, %User{role: :owner}} = Accounts.create_user(owner, new_user_attrs("owner"))
    end

    test "a user creates nobody" do
      assert {:error, :unauthorized} = Accounts.create_user(scope!(%{role: :user}), new_user_attrs("user"))
    end

    test "an admin cannot edit, reset or delete an owner", %{admin: admin} do
      target = scope!(%{role: :owner}).user
      password = %{password: "another long password", password_confirmation: "another long password"}

      assert {:error, :unauthorized} = Accounts.update_user(admin, target, %{"nickname" => "x"})
      assert {:error, :unauthorized} = Accounts.update_user(admin, target, %{"role" => "user"})
      assert {:error, :unauthorized} = Accounts.reset_user_password(admin, target, password)
      assert {:error, :unauthorized} = Accounts.delete_user(admin, target)
      assert %User{role: :owner} = Accounts.get_user(target.id)
    end

    test "an admin holding a stale copy of a since-promoted owner is still refused", %{owner: owner, admin: admin} do
      stale = user!()
      assert {:ok, %User{role: :owner}} = Accounts.update_user(owner, stale, %{"role" => "owner"})
      password = %{password: "another long password", password_confirmation: "another long password"}

      assert {:error, :unauthorized} = Accounts.reset_user_password(admin, stale, password)
      assert {:error, :unauthorized} = Accounts.update_user(admin, stale, %{"role" => "user"})
      assert {:error, :unauthorized} = Accounts.delete_user(admin, stale)
      assert %User{role: :owner} = Accounts.get_user(stale.id)
      assert Accounts.get_user_by_email_and_password(stale.email, @password)
    end

    test "an admin cannot promote to owner but may set a non-owner's role", %{admin: admin} do
      target = user!()

      assert {:error, :unauthorized} = Accounts.update_user(admin, target, %{"role" => "owner"})
      assert {:ok, %User{role: :user}} = Accounts.update_user(admin, target, %{"role" => "user"})
    end

    test "an owner deletes another owner", %{owner: owner} do
      target = scope!(%{role: :owner}).user
      assert {:ok, _} = Accounts.delete_user(owner, target)
    end

    test "nobody changes their own role or deletes themselves", %{owner: owner} do
      assert {:error, :own_role} = Accounts.update_user(owner, owner.user, %{"role" => "user"})
      assert {:error, :self} = Accounts.delete_user(owner, owner.user)
    end
  end

  describe "sudo mode" do
    test "deleting a user needs a confirmed password" do
      admin = %{scope!() | sudo_until: nil}
      target = user!()

      assert Accounts.delete_user(admin, target) == {:error, :sudo_required}
      assert Accounts.enter_sudo(admin, "wrong password") == {:error, :invalid_password}

      assert {:ok, admin} = Accounts.enter_sudo(admin, @password)
      assert {:ok, _} = Accounts.delete_user(admin, target)
    end

    test "repeated wrong passwords are throttled" do
      admin = %{scope!() | sudo_until: nil}
      Throttle.clear({:password, admin.user.id})

      for _ <- 1..5, do: assert(Accounts.enter_sudo(admin, "wrong") == {:error, :invalid_password})

      assert {:error, {:throttled, _}} = Accounts.enter_sudo(admin, @password)
    end

    test "a passwordless user cannot enter it" do
      user = Repo.insert!(User.auto_login_changeset())
      assert Accounts.enter_sudo(Scope.for_user(user), "anything") == {:error, :no_password}
    end

    test "an expired window asks again" do
      admin = %{scope!() | sudo_until: DateTime.add(DateTime.utc_now(:second), -1, :second)}
      refute Accounts.sudo?(admin)
    end
  end
end
