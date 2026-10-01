// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'customer.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CustomerAdapter extends TypeAdapter<Customer> {
  @override
  final int typeId = 0;

  @override
  Customer read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Customer(
      id: fields[0] as String?,
      name: fields[1] as String,
      nameKana: fields[2] as String,
      birthday: fields[3] as DateTime?,
      gender: fields[4] as String?,
      phone: fields[5] as String?,
      lineUserId: fields[6] as String?,
      guardianName: fields[7] as String?,
      guardianPhone: fields[8] as String?,
      recipientCertNumber: fields[9] as String?,
      recipientCertExpiry: fields[10] as DateTime?,
      monthlyAvailableDays: fields[11] as int,
      currentMonthUsedDays: fields[12] as int,
      regularDays: (fields[13] as List?)?.cast<int>(),
      transportLocations: (fields[14] as List?)?.cast<String>(),
      notes: fields[15] as String?,
      createdAt: fields[16] as DateTime?,
      updatedAt: fields[17] as DateTime?,
      isActive: fields[18] as bool,
      transportLocationLats: (fields[19] as List?)?.cast<double?>(),
      transportLocationLngs: (fields[20] as List?)?.cast<double?>(),
      transportLocationStatus: (fields[21] as List?)?.cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, Customer obj) {
    writer
      ..writeByte(22)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.nameKana)
      ..writeByte(3)
      ..write(obj.birthday)
      ..writeByte(4)
      ..write(obj.gender)
      ..writeByte(5)
      ..write(obj.phone)
      ..writeByte(6)
      ..write(obj.lineUserId)
      ..writeByte(7)
      ..write(obj.guardianName)
      ..writeByte(8)
      ..write(obj.guardianPhone)
      ..writeByte(9)
      ..write(obj.recipientCertNumber)
      ..writeByte(10)
      ..write(obj.recipientCertExpiry)
      ..writeByte(11)
      ..write(obj.monthlyAvailableDays)
      ..writeByte(12)
      ..write(obj.currentMonthUsedDays)
      ..writeByte(13)
      ..write(obj.regularDays)
      ..writeByte(14)
      ..write(obj.transportLocations)
      ..writeByte(15)
      ..write(obj.notes)
      ..writeByte(16)
      ..write(obj.createdAt)
      ..writeByte(17)
      ..write(obj.updatedAt)
      ..writeByte(18)
      ..write(obj.isActive)
      ..writeByte(19)
      ..write(obj.transportLocationLats)
      ..writeByte(20)
      ..write(obj.transportLocationLngs)
      ..writeByte(21)
      ..write(obj.transportLocationStatus);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
