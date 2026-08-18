#!/usr/bin/env python3
"""Generate bulk filler creators + campaign history as SQL on stdout.

The hand-written creators are in config/sql/05-seed-showcase.sql. These are the
haystack: without a few thousand rows, filtering means nothing and the percentile
normalisation in fit.creator_fit_scores has nothing to rank against.

Deterministic by design — seeded PRNG, fixed row count. Two runs produce
byte-identical SQL, so the generated file is committed and reviewable in
diffs rather than being a mystery artifact. Re-run only when you mean to
change the data.

Usage:
    python3 scripts/gen-bulk-creators.py > config/sql/07-seed-bulk.sql
    python3 scripts/gen-bulk-creators.py --count 5000 --seed 20260816
"""

import argparse
import random

CATEGORIES = [
    # Weighted so skincare is well represented but far from dominant: the
    # category gate has to actually discriminate.
    ("skincare", 14), ("wellness", 12), ("fashion", 14), ("food", 12),
    ("tech", 10), ("fitness", 10), ("outdoor", 8), ("beauty", 10),
    ("travel", 6), ("home", 4),
]

GEOS = [("US", 46), ("GB", 12), ("CA", 8), ("AU", 6), ("DE", 6),
        ("FR", 5), ("BR", 6), ("IN", 5), ("KR", 3), ("JP", 3)]

AGE_BANDS = [("18-24", 26), ("25-34", 44), ("35-44", 20), ("45-54", 10)]

FIRST = """Ava Liam Noah Emma Olivia Mateo Sofia Yuki Amara Idris Lena Rafael
Nina Omar Chloe Diego Freya Kenji Zara Tobias Marisol Elias Priya Hugo Iris
Sana Lucas Maya Aziz Talia Bruno Ingrid Kofi Suki Nadia Pedro Esme Arjun
Leila Viktor Rosa Ahmed Clara Jonas Amina Felix Yara Marco Hana Otto""".split()

LAST = """Okafor Lindqvist Duarte Nakamura Bergstrom Adeyemi Ferrara Kowalski
Haddad Oyelaran Vasquez Bjornsson Mwangi Rahimi Castellanos Novak Abebe
Solberg Rasmussen Chaudhary Moreau Iversen Delgado Sandoval Petrov Kimura
Fitzgerald Ansari Baptiste Halvorsen Osei Marchetti Zielinski Tanaka
Whitfield Rutherford Nasser Grigorescu Alencar Lindholm Okonkwo Barros
Yeong Casey Ellison Raghunathan Adebayo Lundgren Farrow Mbeki""".split()

HANDLE_A = """quiet slow plain bare true soft raw daily honest minimal clear
calm even open fresh""".split()
HANDLE_B = """glow skin edit routine notes lab diary hours guide method habit
list shelf file study""".split()


def weighted(rng, pairs):
    total = sum(w for _, w in pairs)
    r = rng.uniform(0, total)
    acc = 0.0
    for value, w in pairs:
        acc += w
        if r <= acc:
            return value
    return pairs[-1][0]


def sql_str(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=20260816)
    args = ap.parse_args()

    rng = random.Random(args.seed)

    print("-- GENERATED FILE — do not hand-edit.")
    print(f"-- scripts/gen-bulk-creators.py --count {args.count} --seed {args.seed}")
    print("--")
    print("-- Filler creators so that filtering and percentile normalisation")
    print("-- are meaningful. The hand-written creators are in 05-seed-showcase.sql.")
    print()
    print("BEGIN;")
    print()
    print("DELETE FROM creator.creators WHERE creator_id LIKE 'bulk-%';")
    print()

    creators, perf = [], []
    used_handles = set()

    for i in range(args.count):
        cid = f"bulk-{i:05d}"
        for _ in range(40):
            handle = f"{rng.choice(HANDLE_A)}{rng.choice(HANDLE_B)}{rng.randint(1, 999)}"
            if handle not in used_handles:
                break
        used_handles.add(handle)

        name = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
        category = weighted(rng, CATEGORIES)
        geo = weighted(rng, GEOS)
        age = weighted(rng, AGE_BANDS)

        # Bulk skincare creators are biased AWAY from the US.
        #
        # Without this, generated creators dominate the shortlist and crowd out
        # the hand-written near-misses — a generated creator 34 followers below
        # the floor is a closer miss than a deliberate 12,400 over, so the scout
        # reasonably prefers it.
        #
        # Thinning this intersection keeps 5,000 creators for realistic filtering
        # while leaving the hand-written ones as the answer. Skincare stays well
        # represented globally, which is also plausible.
        if category == "skincare":
            geo = weighted(rng, [("US", 6)] + [(g, w) for g, w in GEOS if g != "US"])

        # Long-tailed follower distribution: mostly nano/micro with a thin
        # mid/macro tail, which is what a real creator base looks like and
        # what makes the micro band a genuine filter.
        r = rng.random()
        if r < 0.34:
            followers = rng.randint(1_000, 9_999)        # nano, below band
        elif r < 0.80:
            followers = rng.randint(10_000, 99_999)      # micro, in band
        elif r < 0.95:
            followers = rng.randint(100_000, 499_999)    # mid, above band
        else:
            followers = rng.randint(500_000, 2_400_000)  # macro

        # Engagement falls as reach grows. The per-tier means below track
        # published influencer benchmarks (nano ~5-6%, micro ~3-4%, mid
        # ~2-3%, macro ~1.5%) rather than a made-up curve.
        #
        # This matters: fit.creator_fit_scores ranks engagement within a follower
        # tier, so too generous a distribution puts the hand-written creators in
        # the bottom deciles of their own tier.
        er_mean, er_sd = {
            "nano":  (0.055, 0.015),
            "micro": (0.035, 0.011),
            "mid":   (0.024, 0.008),
            "macro": (0.016, 0.006),
        }[
            "nano" if followers < 10_000 else
            "micro" if followers < 100_001 else
            "mid" if followers < 500_000 else "macro"
        ]
        engagement = max(0.004, rng.gauss(er_mean, er_sd))

        # Rate tracks reach, loosely. Deliberately noisy so budget and
        # follower gates are not proxies for one another — otherwise the
        # budget exclusion would never be independently interesting.
        rate = round(max(150.0, followers * rng.uniform(0.045, 0.115)), 2)

        geo_share = round(rng.uniform(0.52, 0.94), 3)
        safety = weighted(rng, [(10, 22), (9, 26), (8, 20), (7, 12),
                                (6, 8), (5, 5), (4, 4), (3, 2), (2, 1)])
        last_active = rng.randint(0, 240)

        email = f"{handle}@example.com"
        phone = f"+1-{rng.randint(200, 989)}-555-{rng.randint(100, 9999):04d}"

        creators.append(
            f"({sql_str(cid)},{sql_str(handle)},{sql_str(name)},"
            f"{sql_str(category)},{followers},{engagement:.4f},"
            f"{sql_str(geo)},{geo_share},{sql_str(age)},{safety},{rate},"
            f"{sql_str(email)},{sql_str(phone)},NULL,"
            f"CURRENT_DATE - {last_active})"
        )

        # ~62% of creators carry some campaign history. The rest are
        # genuinely new — which is what makes "discover NEW creators" a
        # real question rather than a re-ranking of the incumbents.
        if rng.random() < 0.62:
            # brand-lumen is excluded here. Its roster is exactly the 14
            # hand-written creators in 06-seed-performance.sql.
            #
            # Without this, "who is our top performer?" returns a random
            # generated macro creator: rate scales with reach, so a 2M-follower
            # filler creator books ~$275k of spend and dwarfs a hand-written
            # micro creator's $3.2k. Keeping generated creators off this brand
            # gives the question one answer, and mirrors reality — brands work
            # with a defined roster, not the whole creator base.
            brand = rng.choice(["brand-verdant", "brand-tenor",
                                "brand-atlas", "brand-saffron", "brand-north"])
            for k in range(rng.randint(1, 4)):
                spend = round(rate * rng.uniform(0.85, 1.25), 2)
                roas = max(0.4, rng.gauss(3.1, 1.5))
                impressions = int(followers * rng.uniform(0.22, 0.68))
                clicks = int(impressions * rng.uniform(0.012, 0.034))
                conversions = int(clicks * rng.uniform(0.018, 0.061))
                posted = 5 + k * 29 + rng.randint(0, 9)
                perf.append(
                    f"({sql_str(f'bulk-camp-{i:05d}-{k}')},{sql_str(cid)},"
                    f"{sql_str(brand)},(CURRENT_DATE - {posted})::date,"
                    f"{impressions},{clicks},{conversions},"
                    f"{round(spend * roas, 2)},{spend})"
                )

    def emit(table, columns, rows, chunk=500):
        for start in range(0, len(rows), chunk):
            batch = rows[start:start + chunk]
            print(f"INSERT INTO {table} ({columns}) VALUES")
            print(",\n".join(batch) + ";")
            print()

    emit("creator.creators",
         "creator_id,handle,display_name,primary_category,follower_count,"
         "avg_engagement_rate,audience_geo_primary,audience_geo_share,"
         "audience_age_band,brand_safety_score,typical_post_rate_usd,"
         "email,phone,bio,last_active_at",
         creators)

    print("DELETE FROM campaign.campaign_performance WHERE campaign_id LIKE 'bulk-camp-%';")
    print()
    emit("campaign.campaign_performance",
         "campaign_id,creator_id,brand_id,posted_at,impressions,clicks,"
         "conversions,gmv_usd,spend_usd",
         perf)

    print("COMMIT;")


if __name__ == "__main__":
    main()
