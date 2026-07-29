-- AskGPT notes: schema for the reader's highlights, notes and AI explanations.
--
-- Records arrive from the e-reader carrying a client-generated `uuid` that is
-- stable for the life of the record. Every upsert matches on (user_id, uuid),
-- which is what makes a re-sent batch a no-op instead of a duplicate.

create extension if not exists pgcrypto;

-- Devices ------------------------------------------------------------------

create table if not exists devices (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references auth.users(id) on delete cascade,
    device_uuid  text not null,
    name         text,
    -- Only the hash is stored; the plaintext token exists on the device alone
    token_hash   text not null,
    created_at   timestamptz not null default now(),
    last_seen_at timestamptz,
    unique (user_id, device_uuid)
);
create index if not exists devices_token_hash_idx on devices (token_hash);

-- Short-lived codes the web app shows and the reader types in. Six characters
-- because e-ink keyboards make long tokens miserable; safe because they expire.
create table if not exists pairing_codes (
    code        text primary key,
    user_id     uuid not null references auth.users(id) on delete cascade,
    expires_at  timestamptz not null,
    consumed_at timestamptz
);

-- Library ------------------------------------------------------------------

create table if not exists books (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users(id) on delete cascade,
    uuid       text not null,
    title      text not null default '',
    authors    text not null default '',
    md5        text,
    updated_at timestamptz not null default now(),
    unique (user_id, uuid)
);

-- A highlight, and the note the reader wrote on it. The AI explanation is
-- deliberately not in here: the device strips it before sending so it is not
-- ingested twice.
create table if not exists items (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users(id) on delete cascade,
    book_id    uuid not null references books(id) on delete cascade,
    uuid       text not null,
    datetime   text,
    text       text,
    note       text,
    chapter    text,
    pageno     integer,
    updated_at timestamptz not null default now(),
    unique (user_id, uuid)
);
create index if not exists items_book_idx on items (book_id, pageno);

create table if not exists conversations (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references auth.users(id) on delete cascade,
    book_id             uuid not null references books(id) on delete cascade,
    uuid                text not null,
    kind                text not null default 'explain',
    highlight           text,
    chapter             text,
    pageno              integer,
    -- Matches items.datetime, which is how a conversation is shown under its highlight
    annotation_datetime text,
    model               text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    unique (user_id, uuid)
);
create index if not exists conversations_book_idx on conversations (book_id, pageno);
create index if not exists conversations_annotation_idx
    on conversations (book_id, annotation_datetime);

create table if not exists messages (
    id              uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references conversations(id) on delete cascade,
    ordinal         integer not null,
    role            text not null,
    content         text not null,
    unique (conversation_id, ordinal)
);

-- Row level security -------------------------------------------------------
-- Readers see only their own rows. Writes come from the sync endpoint, which
-- uses the service role and sets user_id from the device token.

alter table devices       enable row level security;
alter table pairing_codes enable row level security;
alter table books         enable row level security;
alter table items         enable row level security;
alter table conversations enable row level security;
alter table messages      enable row level security;

drop policy if exists devices_own on devices;
create policy devices_own on devices
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists pairing_codes_own on pairing_codes;
create policy pairing_codes_own on pairing_codes
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists books_own on books;
create policy books_own on books
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists items_own on items;
create policy items_own on items
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists conversations_own on conversations;
create policy conversations_own on conversations
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Messages inherit their owner from the conversation
drop policy if exists messages_own on messages;
create policy messages_own on messages
    for all using (
        exists (
            select 1 from conversations c
            where c.id = messages.conversation_id and c.user_id = auth.uid()
        )
    );

-- Counts for the books list, so the page does not have to over-fetch
create or replace view book_summaries
with (security_invoker = true) as
    select b.id, b.user_id, b.title, b.authors, b.updated_at,
           (select count(*) from items i where i.book_id = b.id)          as item_count,
           (select count(*) from items i where i.book_id = b.id
                and i.note is not null and i.note <> '')                  as note_count,
           (select count(*) from conversations c where c.book_id = b.id)  as conversation_count
    from books b;
