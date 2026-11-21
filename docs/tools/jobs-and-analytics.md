---
title: Jobs and analytics
order: 5
description: Watch, stop and retry generation jobs at /jobs, and see token use, spend and speed at /analytics.
---

Every reply, regeneration, continuation, memory run and other AI request runs as a job. **Jobs** at `/jobs` shows the queue live so you can see what is waiting, what is stuck and what failed. **Analytics** at `/analytics` charts what those jobs cost and how fast your models are. Both are in the top bar.

## Jobs

### To find a job

1. Open **Jobs** at `/jobs`. Jobs are listed newest first and update live.
2. In the left pane, pick **All** or one chat. Each entry counts the jobs that still need something (queued, running or awaiting review). The **Jobs** button in a chat's header opens this page already narrowed to that chat.
3. Narrow the list with the **Status** filter (**Any status** or one status), and with **All jobs** or **Memory only** to show every kind or memory jobs alone.

### To stop jobs

- To stop one job, click **Cancel** on its row. Only queued and running jobs can be canceled.
- To stop everything in the current scope, click **Stop all**. You are asked *Stop every queued and running job?* first.
- To stop only memory work, click **Stop memory jobs**.

### To retry a failed job

Click **Retry** on a memory job that failed, was canceled or was interrupted. For a scene memory, **Retry memory only** retries it without running the after-memory side prompts. Chat replies aren't retried here; regenerate them in the chat instead.

### To review or dismiss a job

- A memory job set to wait for review shows **Review**, which opens the draft so you can save or discard it. See [Memory](../memory/index.md).
- **Dismiss** removes a finished job from the list.
- **Raw output** expands the model's raw reply, which helps when a job produced nothing usable.
- **Live output** on a running job shows the text received so far, refreshed every second, so you can tell a slow job from a stuck one.

Each row's details name the model and, when there was one, the prompt that built the request.

### Statuses

| Status | Meaning |
|---|---|
| **Pending** | Queued, waiting for a free slot on the connection. |
| **Running** | Sent to the model and streaming. |
| **Awaiting review** | Finished and waiting for you to accept the result. |
| **Completed** | Finished successfully. |
| **Failed** | Ended with an error, shown on the row. |
| **Canceled** | Stopped by you or by a script. |
| **Interrupted** | Cut off, for example by a server restart. |

Common failure messages include *Stopped: the stream went silent.*, *Stopped: no tokens arrived before the first-token timeout.*, *Stopped: the reply exceeded the output cap.*, *Stopped: the model kept repeating itself.* and *No enabled connection serves this model.* Timeouts come from the model's job time limits; see [Models](../ai/models.md).

### Job kinds

| Kind | What it is |
|---|---|
| **Reply**, **Regenerate**, **Continue**, **Refine** | Chat generations. |
| **Memory**, **Consolidation**, **Compaction**, **Side prompt**, **Topical clip**, **Memory assistance** | Memory work. |
| **Caption** | Describing an image for models that can't see images. |
| **Expression** | Classifying a message's expression. |
| **Assistant** | A reply in a Chat with Mythweaver conversation. |

> [!NOTE]
> Finished chat generations are deleted from the list after a day, and other finished jobs after 30 days. Analytics keeps its own records, so the charts are not affected.

## Analytics

**Analytics** at `/analytics` charts your job runs per day in your browser's time zone. Every job run counts: replies, regenerations and memory work.

### To change what the charts show

- Pick a range of **7 days**, **30 days** (the default) or **90 days**.
- Switch between **Mine** and **All users**. **All users** is available to administrators only.

The page reloads when one of your jobs finishes.

### Charts

| Chart | What it shows |
|---|---|
| **Tokens per day** | Prompt and completion tokens per day, by model. |
| **Cached and uncached prompt tokens per day** | How much of the prompt the backend served from its prompt cache. Cached prompt tokens are cheaper and faster on providers that support caching. |
| **Tokens by model** | Each model's total split into cached prompt, uncached prompt, prompt with cache not reported, and completion. |
| **Spend per day** | Cost per day by model. When the connection reports no cost, it is estimated from the model's prices; a note says how many runs had a known cost and how many were estimated. |
| **Median time to first token** | Per model, with a whisker to the 95th percentile. Timed from when the job started running, so time spent in the queue is left out. |
| **Generation speed** | Median completion tokens per second after the first token, per model. |
| **Outcomes by job type** | Runs by job kind and how they ended: **Completed**, **Awaiting review**, **Failed**, **Canceled** or **Interrupted**. |

A chart with nothing to show in the range shows a note instead, such as *No completed runs in this range.* Set model prices on the model's page to get spend figures; see [Models](../ai/models.md).
