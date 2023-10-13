import 'package:json_annotation/json_annotation.dart';

class BaseCrdtSerializable {
  final int id;

  final String hlc;

  @JsonKey(name: 'node_id')
  final String nodeId;

  final String modified;

  @JsonKey(name: 'is_deleted')
  final int isDeleted;

  BaseCrdtSerializable(this.id, this.hlc, this.nodeId, this.modified, this.isDeleted);
}
