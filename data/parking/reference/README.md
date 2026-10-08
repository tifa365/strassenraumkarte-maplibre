# Pinned Supaplex reference

`upstream/street_parking.py` is fetched from
`SupaplexOSM/street_parking.py` commit
`96debe3635ff7c63800d968270db7ae3b21c48e0` and is retained for comparison.
The current pinned SHA-256 is `cb6417c72be051cce66ad17b51843aa39f8221eab56be8747fb04372aa9eb5d2`.

The execution harness permits only these mechanical changes to a copy used for
reference tests: remove the two redundant unconditional `remove('offset')`
statements; replace the QGIS console bootstrap with explicit input/output
paths; and create/check output directories and writes.  No formulas,
precedence rules, geometry order, defaults, or vehicle distributions are
changed.  Production uses the SQL port and does not import QGIS.

The upstream project remains under its original licence.  Translated rules in
this repository retain attribution and are not relicensed as Apache-2.0.
