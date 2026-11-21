---
title: Character books and locks
order: 5
description: Give each character a memory book of their own, and lock it so it follows them into your other chats.
---

Character books give each character their own memories. In a group chat, every new memory is also copied into the book of each character in the scene, filtered to that character, so on their turn the AI sees what that character experienced. Locking a character to a book carries the book, and everything they remember, into your other chats with them.

## How copies work

When a memory is saved in a chat with character books:

- It is copied into the character book of every character in the scene: those who spoke, plus anyone listed under **Always present (silent witnesses)**. When none of them speaks, every character is included.
- Each copy is filtered to its character. In the chat it was made in, the copy activates on that character's turn instead of the chat's shared memory.
- With a **Character memory prompt** on the profile, each copy is rewritten from that character's perspective. Without one, the copy is the memory verbatim. The built-in **Default** profile has none; pick **Memory: Character** to enable perspective copies (see [Memory profiles](profiles.md)).

Copies show a **Character copy** badge in the **Entries** tab. A copy cannot be regenerated on its own: regenerate the chat's memory and its copies are refreshed. The chat's own memory book can also serve as a character's book.

## To add a character book in a group chat

1. Open the chat's memory window and the **Character books** tab.
2. Select **Add character book**.
3. Pick the **Character** and the **Book** their memories go to.
4. Check **Lock to this book** to carry the book into your other chats with this character.
5. Select **Add**.

The tab lists each character's book, with a **Locked** badge on locked ones. Use **Lock** and **Unlock** to change the lock, and the trash button to remove the character's book.

Removing a character book stops new copies for that character in this chat. The book and its memories stay. If the character was locked to it, removing it also unlocks them in your other chats.

> [!NOTE]
> Only group chats have a **Character books** tab. In a solo chat, lock the memory book to the character instead.

## To lock a solo chat's memory book

1. Open the solo chat's memory window and the **Settings** tab.
2. Select **Lock this book to** *the character*.

The memory book is now locked to the character ("Locked to Mira: this book follows Mira into your other chats."). Select **Unlock from** *the character* to undo it.

## What a lock does

A lock pins one character to one book for all of your chats:

- The book is active in each of your chats the character joins.
- It receives the character's copies of new memories in your group chats.
- A solo chat with the character saves its memories to that book.

Locks are personal: they apply to your chats only, and each user can lock the same character to a different book. A lock takes precedence over a chat's own character book choice.

If the locked book is deleted, the lock goes with it. If the book moves to another owner, or you can no longer edit it, the tab shows "The locked book is no longer available. Unlock to choose another." and the character gets no copies until you unlock them.

## Reference

| Control | Where | What it does |
| --- | --- | --- |
| **Always present (silent witnesses)** | **Settings** tab | Characters included in every new memory of this chat besides whoever speaks. |
| **Add character book** | **Character books** tab | Picks a book for one character in this chat. |
| **Lock to this book** | Add character book form | Also locks the character to the book for your other chats. |
| **Lock** / **Unlock** | **Character books** tab | Locks or unlocks a character's book. |
| **Lock this book to** / **Unlock from** | **Settings** tab (solo chats) | Locks or unlocks the chat's memory book to its character. |
