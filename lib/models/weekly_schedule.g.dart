// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'weekly_schedule.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ScheduleEntryAdapter extends TypeAdapter<ScheduleEntry> {
  @override
  final int typeId = 6;

  @override
  ScheduleEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ScheduleEntry(
      customerId: fields[0] as String,
      customerName: fields[1] as String,
      status: fields[2] as ScheduleStatus,
      plannedStartTime: fields[3] as String?,
      plannedEndTime: fields[4] as String?,
      transportLocationIndex: fields[5] as int?,
      note: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ScheduleEntry obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.customerId)
      ..writeByte(1)
      ..write(obj.customerName)
      ..writeByte(2)
      ..write(obj.status)
      ..writeByte(3)
      ..write(obj.plannedStartTime)
      ..writeByte(4)
      ..write(obj.plannedEndTime)
      ..writeByte(5)
      ..write(obj.transportLocationIndex)
      ..writeByte(6)
      ..write(obj.note);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DailySlotAdapter extends TypeAdapter<DailySlot> {
  @override
  final int typeId = 4;

  @override
  DailySlot read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DailySlot(
      date: fields[0] as DateTime,
      dayOfWeek: fields[1] as int,
      entries: (fields[2] as List?)?.cast<ScheduleEntry>(),
    );
  }

  @override
  void write(BinaryWriter writer, DailySlot obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.date)
      ..writeByte(1)
      ..write(obj.dayOfWeek)
      ..writeByte(2)
      ..write(obj.entries);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DailySlotAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class WeeklyScheduleAdapter extends TypeAdapter<WeeklySchedule> {
  @override
  final int typeId = 3;

  @override
  WeeklySchedule read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WeeklySchedule(
      id: fields[0] as String?,
      weekStartDate: fields[1] as DateTime,
      weekKey: fields[2] as String,
      dailySlots: (fields[3] as List?)?.cast<DailySlot>(),
      createdAt: fields[4] as DateTime?,
      updatedAt: fields[5] as DateTime?,
      note: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, WeeklySchedule obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.weekStartDate)
      ..writeByte(2)
      ..write(obj.weekKey)
      ..writeByte(3)
      ..write(obj.dailySlots)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.updatedAt)
      ..writeByte(6)
      ..write(obj.note);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeeklyScheduleAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ScheduleStatusAdapter extends TypeAdapter<ScheduleStatus> {
  @override
  final int typeId = 5;

  @override
  ScheduleStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ScheduleStatus.planned;
      case 1:
        return ScheduleStatus.additional;
      case 2:
        return ScheduleStatus.cancelled;
      default:
        return ScheduleStatus.planned;
    }
  }

  @override
  void write(BinaryWriter writer, ScheduleStatus obj) {
    switch (obj) {
      case ScheduleStatus.planned:
        writer.writeByte(0);
        break;
      case ScheduleStatus.additional:
        writer.writeByte(1);
        break;
      case ScheduleStatus.cancelled:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduleStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
