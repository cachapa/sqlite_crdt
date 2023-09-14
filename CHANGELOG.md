## 2.1.0

- Update to latest `sql_crdt` version

## 2.0.0

- Update to latest `sql_crdt` version

## 1.1.1+2

- Add `CrdtChangeset` type alias

## 1.1.1+1

- Default `singleInstance` to false when opening a database in memory

## 1.1.1

- Fix change notifications when no changes were made
- Guard against a possible race condition when setting the canonical time

## 1.1.0

- Breaking: return Hlc.zero instead of null in `lastModified`
- Breaking: allow specifying nodeIds in `getChangeset`
- Add getter for all tables in database
- Allow watching changed tables to enable atomic sync operations
- Removed convenience getter `peerLastModified`
- Do not merge empty changesets

## 1.0.3

- Update to Dart 3.0
- Fix watch argument generator not being re-run on every query

## 1.0.2

- Print malformed queries when using watch()

## 1.0.1

- Update to latest sql_crdt

## 1.0.0

- Make SqlCrdt abstract

## 0.0.9+4

- Add some more documentation

## 0.0.9+3

- Add documentation

## 0.0.9+2

- Warn when web binaries are missing from project

## 0.0.9+1

- Make dart:io conditional import

## 0.0.9

- Add support for upsert and replace statements
- Add experimental web support
 
## 0.0.8+1

- Fix the getChangeset query

## 0.0.8

- Dedicated node_id column to improve query performance
- Add method to reset node id
- Improve merge error reporting

## 0.0.7

* Move database-agnostic code to sql_crdt

## 0.0.6

* Refactor path instantiation

## 0.0.5+1

* Fix UPSERTs on Raspbian due to older Sqlite version

## 0.0.4

* Warn instead of bailing on unparseable queries

## 0.0.3

* Refactor entire project to fix transaction deadlocks

## 0.0.2

* Remove ORM-like write methods
* Intercept SQL write queries and perform CRDT magic transparently
* Add watchChangeset method
* Refactor Hlc
* Add Hlc tests

## 0.0.1

* Initial release.
