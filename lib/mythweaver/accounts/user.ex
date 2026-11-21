defmodule Mythweaver.Accounts.User do
  @moduledoc """
  An account. Email identifies it for login (case-insensitively, `citext`), is private to the account
  and `users.manage` holders, and can change; `handle` is the unique public name (lowercase
  `[a-z0-9_]`, 3–20 characters, shown `@handle`) and can change; `nickname` is optional display
  text. `hashed_password` is nil only for the auto-login admin
  (`auto_login_changeset/0`) until a password is set.
  """
  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User

  @type t :: %__MODULE__{}
  @type role :: :owner | :user

  schema "users" do
    field :email, :string
    field :handle, :string
    field :nickname, :string
    field :role, Ecto.Enum, values: [:owner, :user], default: :user
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    # Set only by `Mythweaver.Accounts.put_browser_locale/2`, never cast.
    field :browser_locale, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for creating an account: email, handle, optional nickname, password and confirmation.

  ## Options

    * `:validate_unique` - checks email and handle uniqueness against the database. Defaults to
      `true`; pass `false` for live validation.
    * `:hash_password` - hashes the password and clears the plain field. Defaults to `true`; pass
      `false` for live validation.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :handle, :nickname, :password])
    |> validate_email(opts)
    |> validate_handle(opts)
    |> validate_nickname()
    |> validate_confirmation(:password, message: dgettext_noop("errors", "does not match password"))
    |> validate_password(opts)
  end

  @doc """
  A changeset for editing email, handle and nickname. An unchanged email is legal, since the form
  submits it together with the nickname. Takes the `:validate_unique` option of
  `registration_changeset/3`.
  """
  def profile_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :handle, :nickname])
    |> validate_email(opts)
    |> validate_handle(opts)
    |> validate_nickname()
  end

  @doc """
  A changeset for changing the password.

  It is important to validate the length of the password, as long passwords may be very expensive
  to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely in the database and
      ensures the password field is cleared to prevent leaks in the logs. Defaults to `true`; set
      `false` for LiveView form validation.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: dgettext_noop("errors", "does not match password"))
    |> validate_password(opts)
  end

  @doc """
  Checks `password` against the stored hash, adding a `:current_password` error on mismatch. A user
  without a password has nothing to check, so the changeset passes through.
  """
  def validate_current_password(changeset, password) do
    changeset = cast(changeset, %{current_password: password}, [:current_password])

    cond do
      is_nil(changeset.data.hashed_password) -> changeset
      valid_password?(changeset.data, password) -> changeset
      true -> add_error(changeset, :current_password, dgettext_noop("errors", "is not valid"))
    end
  end

  @doc "The passwordless owner auto-login creates on an install with no accounts."
  def auto_login_changeset,
    do: change(%User{}, email: "admin@localhost", handle: "admin", nickname: "Admin", role: :owner)

  @doc "Sets `role` (an atom or its string form). Only `Mythweaver.Accounts` calls it, after its role checks."
  def role_changeset(user_or_changeset, role) do
    user_or_changeset
    |> cast(%{role: role}, [:role])
    |> validate_required([:role])
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call `Bcrypt.no_user_verify/0` to
  avoid timing attacks.
  """
  def valid_password?(%User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc "The name shown for a user: the nickname, or `@handle` when there is none. Never the email."
  def display_name(%User{nickname: nil, handle: handle}), do: "@" <> handle
  def display_name(%User{nickname: nickname}), do: nickname

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: dgettext_noop("errors", "must have the @ sign and no spaces")
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Mythweaver.Repo)
      |> unique_constraint(:email)
    else
      changeset
    end
  end

  defp validate_handle(changeset, opts) do
    changeset =
      changeset
      |> update_change(:handle, &normalize_handle/1)
      |> validate_required([:handle])
      |> validate_length(:handle, min: 3, max: 20)
      |> validate_format(:handle, ~r/^[a-z0-9_]+$/,
        message: dgettext_noop("errors", "may only use letters, numbers and underscores")
      )

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:handle, Mythweaver.Repo)
      |> unique_constraint(:handle)
    else
      changeset
    end
  end

  @doc false
  def normalize_handle(nil), do: nil
  def normalize_handle(handle), do: handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

  defp validate_nickname(changeset) do
    changeset
    |> update_change(:nickname, &blank_to_nil/1)
    |> validate_length(:nickname, max: 50)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(nickname) do
    case String.trim(nickname) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Bcrypt only reads the first 72 bytes.
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that would keep the
      # database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
