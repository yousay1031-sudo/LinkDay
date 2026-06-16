// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'attendance_record.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AttendanceRecordAdapter extends TypeAdapter<AttendanceRecord> {
  @override
  final int typeId = 1;

  @override
  AttendanceRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AttendanceRecord(
      id: fields[0] as String?,
      customerId: fields[1] as String,
      customerName: fields[2] as String,
      dateKey: fields[3] as String,
      status: fields[4] as AttendanceStatus,
      plannedStartTime: fields[5] as DateTime?,
      plannedEndTime: fields[6] as DateTime?,
      checkInTime: fields[7] as DateTime?,
      checkOutTime: fields[8] as DateTime?,
      absenceReason: fields[9] as String?,
      note: fields[10] as String?,
      createdAt: fields[11] as DateTime?,
      updatedAt: fields[12] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, AttendanceRecord obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.customerId)
      ..writeByte(2)
      ..write(obj.customerName)
      ..writeByte(3)
      ..write(obj.dateKey)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.plannedStartTime)
      ..writeByte(6)
      ..write(obj.plannedEndTime)
      ..writeByte(7)
      ..write(obj.checkInTime)
      ..writeByte(8)
      ..write(obj.checkOutTime)
      ..writeByte(9)
      ..write(obj.absenceReason)
      ..writeByte(10)
      ..write(obj.note)
      ..writeByte(11)
      ..write(obj.createdAt)
      ..writeByte(12)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttendanceRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AttendanceStatusAdapter extends TypeAdapter<AttendanceStatus> {
  @override
  final int typeId = 2;

  @override
  AttendanceStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AttendanceStatus.scheduled;
      case 1:
        return AttendanceStatus.present;
      case 2:
        return AttendanceStatus.departed;
      case 3:
        return AttendanceStatus.absent;
      default:
        return AttendanceStatus.scheduled;
    }
  }

  @override
  void write(BinaryWriter writer, AttendanceStatus obj) {
    switch (obj) {
      case AttendanceStatus.scheduled:
        writer.writeByte(0);
        break;
      case AttendanceStatus.present:
        writer.writeByte(1);
        break;
      case AttendanceStatus.departed:
        writer.writeByte(2);
        break;
      case AttendanceStatus.absent:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AttendanceStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
