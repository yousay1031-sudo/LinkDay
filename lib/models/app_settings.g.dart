// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_settings.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AppSettingsAdapter extends TypeAdapter<AppSettings> {
  @override
  final int typeId = 7;

  @override
  AppSettings read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AppSettings(
      facilityName: fields[0] as String,
      facilityAddress: fields[1] as String,
      facilityLat: fields[2] as double?,
      facilityLng: fields[3] as double?,
      vehicleCount: fields[4] as int,
      vehicleNames: (fields[5] as List?)?.cast<String>(),
      vehicleCapacities: (fields[6] as List?)?.cast<int>(),
      maxStudentsPerDay: fields[7] as int,
      defaultPickupStart: fields[8] as String,
      defaultDropoffEnd: fields[9] as String,
      updatedAt: fields[10] as DateTime?,
      jsApiKeyLegacy: fields[11] as String?,
      restApiKeyLegacy: fields[12] as String?,
      vacancyReplyDeadline: fields[13] as String?,
      vacancyMessageTemplate: fields[14] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.facilityName)
      ..writeByte(1)
      ..write(obj.facilityAddress)
      ..writeByte(2)
      ..write(obj.facilityLat)
      ..writeByte(3)
      ..write(obj.facilityLng)
      ..writeByte(4)
      ..write(obj.vehicleCount)
      ..writeByte(5)
      ..write(obj.vehicleNames)
      ..writeByte(6)
      ..write(obj.vehicleCapacities)
      ..writeByte(7)
      ..write(obj.maxStudentsPerDay)
      ..writeByte(8)
      ..write(obj.defaultPickupStart)
      ..writeByte(9)
      ..write(obj.defaultDropoffEnd)
      ..writeByte(10)
      ..write(obj.updatedAt)
      ..writeByte(11)
      ..write(obj.jsApiKeyLegacy)
      ..writeByte(12)
      ..write(obj.restApiKeyLegacy)
      ..writeByte(13)
      ..write(obj.vacancyReplyDeadline)
      ..writeByte(14)
      ..write(obj.vacancyMessageTemplate);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettingsAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
