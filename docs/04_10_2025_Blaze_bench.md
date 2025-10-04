# OpenAPI deep-dive — Checklist

## 1) “Are conditionals the issue, or what’s inside them?”

**What we did**

* Counted `$ref` overall vs **inside conditionals** on the OpenAPI bundle:

  * Total `$ref`: **137**
  * `$ref` under `if/then/else`: **19**
* Timed targeted ablations (normal mode):

```
baseline                ≈ 1:13 (422 MB)
no-conditionals         ≈ 0:01.22 (16 MB)
conditionals-empty      ≈ 0:45.13 (422 MB)
no-refs-inside-cond.    ≈ 0:44.62 (422 MB)
```

**Conclusion**

* Removing conditionals = instant speedup → **conditionals are key**.
* Keeping conditionals but **empty bodies** is still slow → **wrappers themselves** are expensive.
* Removing `$ref` *inside* conditionals changes little → **payload not the main culprit**.

---

## 2) “Is it the same exponential `$ref` issue?”

**What we did**

* Observed OpenAPI & OMC are slow, but OpenAPI ablations show slowness persists even when refs-in-conditionals are stripped.
* Built synthetic schemas to isolate mechanics (see §3). Those show the blow-up without needing `$ref` payload complexity.

**Conclusion**

* The dominant cost here is **`if/then/else` traversal interacting with structure (esp. with `allOf`)**.
* `$ref` can amplify in real schemas, but isn’t required to trigger the blow-up in our synthetic case.

---

## 3) “Can you build a minimum reproducible schema (lots of `allOf` + conditionals)?”

**What we did**

* Wrote a generator: **`gen_hot_schema.py`** (produces many blocks of `allOf + if/then/else (+$ref)`).
* Confirmed scaling:

**Depth sweep (width=120):**

* d=6  → **~1.4s**, peak heap ~**0.05 GB**
* d=12 → **~4.0s**, peak heap ~**0.14 GB**
* d=18 → **~13.2s**, peak heap ~**0.42 GB**

**Width sweep (depth=12):**

* w=60  → **~2.75s**, ~**0.09 GB**
* w=120 → **~6.71s**, ~**0.21 GB**
* w=240 → **~14.44s**, ~**0.38 GB**

**Key ablations on synthetic (width=120, depth=12):**

```
baseline                  ~ 4s / 508 MB
no-conditionals           ~ 0.03s
conditionals-empty        ~ 4s / 508 MB   (same as baseline)
no-refs-inside-conds      ~ 4s / 508 MB
only-allof                ~ 0.03s
no-allof                  ~ 0.01s
```

**Conclusion**

* **Depth** is the super-linear pain driver; **width** is ~linear.
* Either removing **conditionals** or removing **allOf** collapses cost.

---

## 4) “Profile memory to see where we allocate so much”

**What we did**

* Ran **Valgrind Massif** on the synthetic “hot_min” case (width=60, depth=12):

**Peaks**

* `baseline` / `conditionals-empty`: **~240 MB** peak heap
* `no-conditionals`: **~2 MB**
* `no-allof`: **~0.5 MB**

**Top stack (Massif)**

* Repeated allocations inside the schema **walker** over nested `allOf + if/then/else`:

  * `(anonymous namespace)::walk(...)` and related frames dominate.

**Conclusion**

* The heavy allocator path is the **conditional walker recursion** (amplified by depth + `allOf`), not `$ref` payload resolution.

---