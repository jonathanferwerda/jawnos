# 2. One big table and its satellites

*Sample chapter for the TPF application — §2 of the architecture guide. Roughly two pages.*

---

A schema is an argument about what the world is made of. Most business software argues that the world
is made of nouns: customers, orders, products, payments, each with its own table and its own
relationships. JawnOS argues something narrower and stranger: **most of a life is an appointment** — a
thing that happened, or will, with a type and a body.

That argument is the reason a person window, a ledger, a calendar, and a search box can all be the
same feature.

## The table

`appointments` has a little over fifty columns. They fall into groups:

| Group | Columns |
| --- | --- |
| Identity | `uuid`, `app`, `type`, `subtype`, `app_uuid`, `source_uuid`, `ticket_uuid` |
| Time | `timestamp`, `server_time`, `ost`, `duration`, `stop_timestamp`, `seen`, `stop_seen`, `duties`, `next_duty` |
| Who and what | `account`, `project`, `vendor`, `club`, `item`, `model`, `manufacturer` |
| Money | `amount`, `unit`, `quantity`, `total`, `tax`, `currency`, `balance`, `has_tax`, `has_totes` |
| Body | `data`, `file`, `notes`, `start_notes`, `end_notes`, `options`, `measures`, `formulas` |
| State | `movement`, `status`, `state`, `toggle`, `position`, `pos`, `warranty` |
| Machine | `device`, `browser_tab_id` |

The rule is not "one type per column". It is: **a column exists when something filters or indexes on
it; everything else goes in `data`.** Money is queried, so `amount` and `total` are columns. Line
items, tax breakdowns, payment lists, and invoice numbering are not, so they live in a JSON payload.

## Why one shape

Three queries carry most of the application.

*Everything about a person.* One window gathers what you sold them, what you said to them, when you
are seeing them next, and what they still owe — because all of those are rows with their `app` and
`account` set, not four tables joined by three relations.

*What happened in March.* The timeline, the ledger, and search are the same range scan. The calendar
does not need to know that a row is an invoice; it needs to know when the row is.

*A stop can arrive later.* A session started at nine and closed at eleven may be closed from another
machine, hours afterwards. That is why `stop_timestamp` and `stop_seen` exist beside `timestamp` and
`seen`: closing is a second event, and the mesh has to order it. It is also why the record audit
exists — a stop that lands on the wrong row is the characteristic corruption of this model, and the
repair has to be explicit.

## What earned a satellite

A few things genuinely are not prose, and they got their own tables:

| Table | Why it is not an appointment |
| --- | --- |
| `warehouse` | A stock move needs a signed quantity and a place. Income and pulls are negative; expenses and adds are positive. Money moves stay in `appointments` and are joined by uuid, so nothing is counted twice. |
| `mailbox` | Messages carry headers, threads, recipients, and IMAP-shaped state. A message body is not a note. |
| `notes` | The scratch pad: its own timestamp, its own lifecycle, no type. |
| `model`, `option`, `subcategory` | Reusable catalogue and settings. They are definitions, not events. |
| `continent` | Places and coordinates. A pin is not a sentence. |
| `magazine` | Article and page content: title, teaser, colours, status. |
| `credentials` | The keyboard's vault. The payload is encrypted; only the non-secret metadata is queryable. |
| `devices` | This machine's view of the house. Deliberately not shared: restoring one machine's database onto another breaks its identity. |

The rule of thumb that survived four years:

> **Does it have a date, a person, or an amount? Appointment. Does it need a signed quantity, geometry,
> a protocol, or its own lifecycle? Satellite.**

## The cost

The table is wide, sparse, and not tidy.

Every value is stored as text, including numbers and timestamps. SQLite's dynamic typing makes this
work, but comparisons, sums, and date arithmetic all depend on every writer formatting consistently.
There are no foreign keys. The schema grew by `ALTER TABLE ... ADD COLUMN`, applied once per worker at
startup and tracked so a restart with no schema change is cheap; `database/schema.sql` is the
accumulated result, not a design document.

The indexes carry the weight:

- `(app, timestamp)` for a window on one app
- `(timestamp, seen)` for what is new
- `(timestamp, stop_timestamp, seen, stop_seen)` for open sessions
- `(stop_timestamp, stop_seen)` for the stop path
- `(duties, next_duty)` for what is due
- `(app, server_time, status)` for sync and reconciliation

One caution is worth recording because it cost a real afternoon: a query that asked for
`stop_timestamp between ? and ?` **or** `stop_timestamp is null` made the planner walk every
never-stopped row — about 74,000 of them — before the predicate was split. In this model, the absence
of a stop is a first-class case, not an edge case.

## Sync, and why one table helps

Every synced row carries `uuid`, `ost`, `server_time`, and `device`. `ost` is stamped when the row is
first written and then preserved; `server_time` records the last write. Together they give the mesh an
order for writes that happened on different machines with no clock to agree on.

Deletions propagate as tombstones, so an offline peer cannot resurrect a row it never heard was
removed. The bookkeeping lives in four small tables: `sync_log` records what was sent, `sync_cursors`
remembers where each peer has read to, `sync_jobs` tracks a job's phases and progress, and
`sync_snapshots` holds the archive a job produced.

`staged_appointments` is the exception that proves the rule: when an agent proposes a change, it is
written as a staged row with `kind`, `target_uuid`, and `changes`, and it becomes real only when a
person promotes it. The table is the same shape; the status is what makes it a proposal.

## A worked example: the invoice payment

An invoice is an appointment with `type = 'invoice'`, `movement = 'income'`, and a `data` payload:

```json
{
  "id": "1092026-5de3",
  "numbers": { "subtotal": 120, "tax": 15.6, "discount": 0, "total": 135.6,
               "balance": 135.6, "cost": 60, "markup": 60, "tax_rate": 0.13 },
  "payments": []
}
```

Recording a payment writes a *transaction* appointment and then pushes onto the invoice:

```json
{ "account": "bank", "amount": 135.6, "timestamp": 1790000000000,
  "appt_uuid": "<the transaction>", "uuid": "<this payment>" }
```

The invoice's `numbers.balance` drops, and when it reaches zero the invoice's `status` becomes
`completed`. Deleting the transaction runs the reverse path: the payment is removed from
`data.payments`, the balance is restored, and a completed invoice reopens. The relationship between
the invoice and the payment is a uuid, not a join table.

That is the whole argument in one feature. The ledger entry, the invoice, and the calendar event are
the same kind of row, so the books can reconcile against the calendar without an integration layer.

## What I would do differently

- **A type registry.** `app` and `type` are free text today. A `types` table with a foreign key would
  make the vocabulary explicit and let the UI enumerate it honestly.
- **Typed projections.** Money as integer cents and timestamps as integers in narrow read tables,
  rebuilt on write, rather than text columns the planner has to scan.
- **A real migration ledger.** Idempotent `ALTER TABLE` attempts are cheap to write and impossible to
  read in order. Named migrations with a date would make the schema's history legible.
- **Foreign keys** on the relationships that matter — payment to transaction, stop to start, staged row
  to target.

I would keep the one-table decision. Everything in this list is a way to make the edges sharper
without giving up the thing that makes the person window, the ledger, and the calendar a single
feature.
