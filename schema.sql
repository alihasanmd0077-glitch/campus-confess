-- ═══════════════════════════════════════════════════════════════
--  CampusConfess — Supabase SQL Schema
--  Run this in your Supabase project → SQL Editor → New Query
-- ═══════════════════════════════════════════════════════════════


-- ─── 1. CONFESSIONS TABLE ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.confessions (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  content         TEXT          NOT NULL CHECK (char_length(content) BETWEEN 10 AND 500),
  category        TEXT          NOT NULL DEFAULT 'general'
                                CHECK (category IN ('general','crush','regret','funny','secret','rant')),
  campus          TEXT,                          -- optional college name
  likes_count     INTEGER       NOT NULL DEFAULT 0 CHECK (likes_count >= 0),
  comments_count  INTEGER       NOT NULL DEFAULT 0 CHECK (comments_count >= 0),
  is_approved     BOOLEAN       NOT NULL DEFAULT TRUE,   -- set FALSE for moderation queue
  is_flagged      BOOLEAN       NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX idx_confessions_created_at  ON public.confessions (created_at DESC);
CREATE INDEX idx_confessions_category    ON public.confessions (category);
CREATE INDEX idx_confessions_campus      ON public.confessions (campus) WHERE campus IS NOT NULL;
CREATE INDEX idx_confessions_likes       ON public.confessions (likes_count DESC);


-- ─── 2. COMMENTS TABLE ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.comments (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  confession_id   UUID          NOT NULL REFERENCES public.confessions(id) ON DELETE CASCADE,
  content         TEXT          NOT NULL CHECK (char_length(content) BETWEEN 1 AND 300),
  is_flagged      BOOLEAN       NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_comments_confession_id ON public.comments (confession_id, created_at ASC);


-- ─── 3. LIKES TABLE (optional — for deduplication) ───────────────
-- Stores a fingerprint so the same browser can't like twice.
-- No user data stored — just a hashed client fingerprint.
CREATE TABLE IF NOT EXISTS public.likes (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  confession_id   UUID          NOT NULL REFERENCES public.confessions(id) ON DELETE CASCADE,
  fingerprint     TEXT          NOT NULL,        -- hashed browser fingerprint (no PII)
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE (confession_id, fingerprint)
);

CREATE INDEX idx_likes_confession_id ON public.likes (confession_id);


-- ─── 4. FLAGS / REPORTS TABLE ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reports (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  confession_id   UUID          REFERENCES public.confessions(id) ON DELETE CASCADE,
  comment_id      UUID          REFERENCES public.comments(id)    ON DELETE CASCADE,
  reason          TEXT          NOT NULL CHECK (reason IN ('spam','harassment','hate','other')),
  details         TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CHECK (
    (confession_id IS NOT NULL AND comment_id IS NULL) OR
    (confession_id IS NULL AND comment_id IS NOT NULL)
  )
);


-- ─── 5. AUTO-UPDATE updated_at TRIGGER ───────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_confessions_updated_at
  BEFORE UPDATE ON public.confessions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ─── 6. ROW LEVEL SECURITY (RLS) ─────────────────────────────────
-- Enable RLS on all tables
ALTER TABLE public.confessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports     ENABLE ROW LEVEL SECURITY;

-- CONFESSIONS — anyone can read approved, non-flagged confessions
CREATE POLICY "Public can read confessions"
  ON public.confessions FOR SELECT
  USING (is_approved = TRUE AND is_flagged = FALSE);

-- CONFESSIONS — anyone (anon) can insert
CREATE POLICY "Anyone can insert confession"
  ON public.confessions FOR INSERT
  WITH CHECK (TRUE);

-- CONFESSIONS — anyone can update likes/comments counts only
CREATE POLICY "Anyone can update counts"
  ON public.confessions FOR UPDATE
  USING (TRUE)
  WITH CHECK (TRUE);

-- COMMENTS — public read
CREATE POLICY "Public can read comments"
  ON public.comments FOR SELECT
  USING (is_flagged = FALSE);

-- COMMENTS — anyone can insert
CREATE POLICY "Anyone can insert comment"
  ON public.comments FOR INSERT
  WITH CHECK (TRUE);

-- LIKES — anyone can insert/select
CREATE POLICY "Anyone can like"
  ON public.likes FOR INSERT
  WITH CHECK (TRUE);

CREATE POLICY "Anyone can read likes"
  ON public.likes FOR SELECT
  USING (TRUE);

CREATE POLICY "Anyone can delete own like"
  ON public.likes FOR DELETE
  USING (TRUE);

-- REPORTS — anyone can report
CREATE POLICY "Anyone can report"
  ON public.reports FOR INSERT
  WITH CHECK (TRUE);


-- ─── 7. REALTIME PUBLICATION ─────────────────────────────────────
-- Enable Realtime for live feed updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.confessions;
ALTER PUBLICATION supabase_realtime ADD TABLE public.comments;


-- ─── 8. HELPFUL VIEWS ────────────────────────────────────────────

-- Trending confessions (last 24 hours, sorted by likes)
CREATE OR REPLACE VIEW public.trending_confessions AS
SELECT *
FROM public.confessions
WHERE is_approved = TRUE
  AND is_flagged  = FALSE
  AND created_at  >= NOW() - INTERVAL '24 hours'
ORDER BY likes_count DESC, created_at DESC
LIMIT 20;

-- Stats summary view
CREATE OR REPLACE VIEW public.confession_stats AS
SELECT
  COUNT(*)                                          AS total_confessions,
  COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '24h') AS today_confessions,
  SUM(likes_count)                                  AS total_likes,
  AVG(likes_count)::NUMERIC(10,2)                   AS avg_likes,
  COUNT(DISTINCT campus) FILTER (WHERE campus IS NOT NULL) AS campuses_represented
FROM public.confessions
WHERE is_approved = TRUE AND is_flagged = FALSE;

-- Category breakdown
CREATE OR REPLACE VIEW public.category_counts AS
SELECT
  category,
  COUNT(*)          AS count,
  SUM(likes_count)  AS total_likes
FROM public.confessions
WHERE is_approved = TRUE AND is_flagged = FALSE
GROUP BY category
ORDER BY count DESC;


-- ─── 9. SEED DATA (optional — remove in production) ──────────────
INSERT INTO public.confessions (content, category, campus, likes_count, comments_count) VALUES
  ('I studied the night before every single exam for 4 years and somehow graduated with honors. The all-nighter is a lifestyle, not a strategy.',
   'funny', 'Generic University', 42, 7),
  ('I have had a crush on the same person in my department for two years. We sit next to each other every class and I still haven''t said anything beyond "did you understand question 3?"',
   'crush', NULL, 89, 14),
  ('I submitted an assignment I wrote entirely in 20 minutes while waiting for a bus. I got 91%. I don''t know how to feel about this.',
   'secret', 'Delhi University', 56, 3),
  ('I genuinely think the food in the hostel mess has made me a stronger person. What doesn''t kill you makes you tougher.',
   'rant', NULL, 33, 9),
  ('I regret not joining any clubs in first year because I thought I was "too busy". I wasn''t busy. I was just scared.',
   'regret', NULL, 112, 21);


-- ═══════════════════════════════════════════════════════════════
--  SETUP CHECKLIST
-- ═══════════════════════════════════════════════════════════════
--  1. Go to supabase.com → New Project
--  2. Open SQL Editor → New Query → paste this file → Run
--  3. Go to Project Settings → API
--  4. Copy "Project URL" → paste as SUPABASE_URL in the HTML
--  5. Copy "anon public" key → paste as SUPABASE_ANON_KEY in the HTML
--  6. Go to Database → Replication → enable confessions & comments tables
--  7. Deploy your HTML file or host it anywhere (Netlify, Vercel, etc.)
-- ═══════════════════════════════════════════════════════════════
