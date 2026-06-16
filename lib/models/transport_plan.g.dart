// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'transport_plan.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TransportStopAdapter extends TypeAdapter<TransportStop> {
  @override
  final int typeId = 9;

  @override
  TransportStop read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TransportStop(
      customerId: fields[0] as String,
      customerName: fields[1] as String,
      address: fields[2] as String,
      lat: fields[3] as double?,
      lng: fields[4] as double?,
      orderIndex: fields[5] as int,
      scheduledTime: fields[6] as String?,
      distanceFromPrevMeters: fields[7] as int?,
      durationFromPrevSeconds: fields[8] as int?,
      note: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, TransportStop obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.customerId)
      ..writeByte(1)
      ..write(obj.customerName)
      ..writeByte(2)
      ..write(obj.address)
      ..writeByte(3)
      ..write(obj.lat)
      ..writeByte(4)
      ..write(obj.lng)
      ..writeByte(5)
      ..write(obj.orderIndex)
      ..writeByte(6)
      ..write(obj.scheduledTime)
      ..writeByte(7)
      ..write(obj.distanceFromPrevMeters)
      ..writeByte(8)
      ..write(obj.durationFromPrevSeconds)
      ..writeByte(9)
      ..write(obj.note);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportStopAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TransportVehicleRouteAdapter extends TypeAdapter<TransportVehicleRoute> {
  @override
  final int typeId = 8;

  @override
  TransportVehicleRoute read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TransportVehicleRoute(
      id: fields[0] as String?,
      vehicleName: fields[1] as String,
      vehicleIndex: fields[2] as int,
      transportType: fields[3] as TransportType,
      dateKey: fields[4] as String,
      stops: (fields[5] as List?)?.cast<TransportStop>(),
      capacity: fields[6] as int,
      googleMapsUrl: fields[7] as String?,
      totalDistanceMeters: fields[8] as int?,
      totalDurationSeconds: fields[9] as int?,
      optimizedAt: fields[10] as DateTime?,
      note: fields[11] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, TransportVehicleRoute obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.vehicleName)
      ..writeByte(2)
      ..write(obj.vehicleIndex)
      ..writeByte(3)
      ..write(obj.transportType)
      ..writeByte(4)
      ..write(obj.dateKey)
      ..writeByte(5)
      ..write(obj.stops)
      ..writeByte(6)
      ..write(obj.capacity)
      ..writeByte(7)
      ..write(obj.googleMapsUrl)
      ..writeByte(8)
      ..write(obj.totalDistanceMeters)
      ..writeByte(9)
      ..write(obj.totalDurationSeconds)
      ..writeByte(10)
      ..write(obj.optimizedAt)
      ..writeByte(11)
      ..write(obj.note);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportVehicleRouteAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TransportTypeAdapter extends TypeAdapter<TransportType> {
  @override
  final int typeId = 10;

  @override
  TransportType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TransportType.pickup;
      case 1:
        return TransportType.dropoff;
      default:
        return TransportType.pickup;
    }
  }

  @override
  void write(BinaryWriter writer, TransportType obj) {
    switch (obj) {
      case TransportType.pickup:
        writer.writeByte(0);
        break;
      case TransportType.dropoff:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
