// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_log.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class NotificationLogAdapter extends TypeAdapter<NotificationLog> {
  @override
  final int typeId = 11;

  @override
  NotificationLog read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NotificationLog(
      id: fields[0] as String?,
      customerId: fields[1] as String,
      childName: fields[2] as String,
      dateKey: fields[3] as String,
      status: fields[4] as NotificationStatus,
      sentAt: fields[5] as DateTime?,
      httpStatus: fields[6] as int?,
      error: fields[7] as String?,
      lineUserIdSuffix: fields[8] as String?,
      message: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, NotificationLog obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.customerId)
      ..writeByte(2)
      ..write(obj.childName)
      ..writeByte(3)
      ..write(obj.dateKey)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.sentAt)
      ..writeByte(6)
      ..write(obj.httpStatus)
      ..writeByte(7)
      ..write(obj.error)
      ..writeByte(8)
      ..write(obj.lineUserIdSuffix)
      ..writeByte(9)
      ..write(obj.message);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationLogAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NotificationStatusAdapter extends TypeAdapter<NotificationStatus> {
  @override
  final int typeId = 12;

  @override
  NotificationStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NotificationStatus.sent;
      case 1:
        return NotificationStatus.failed;
      case 2:
        return NotificationStatus.duplicate;
      case 3:
        return NotificationStatus.invalidLineUserId;
      default:
        return NotificationStatus.sent;
    }
  }

  @override
  void write(BinaryWriter writer, NotificationStatus obj) {
    switch (obj) {
      case NotificationStatus.sent:
        writer.writeByte(0);
        break;
      case NotificationStatus.failed:
        writer.writeByte(1);
        break;
      case NotificationStatus.duplicate:
        writer.writeByte(2);
        break;
      case NotificationStatus.invalidLineUserId:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NotificationStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
