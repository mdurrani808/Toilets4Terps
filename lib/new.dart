import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocode/geocode.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geocoder_buddy/geocoder_buddy.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
      url: 'https://gggtostjtbrnkemvaafb.supabase.co',
      anonKey:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdnZ3Rvc3RqdGJybmtlbXZhYWZiIiwicm9sZSI6ImFub24iLCJpYXQiOjE2OTM2MjA2OTQsImV4cCI6MjAwOTE5NjY5NH0.MM1gQ-B9mEdynHEsQYch4njVnzvPEXA2ls3kYalVCkk',
      headers: {
        "Access-Control-Allow-Origin": "*",
      });

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Location List',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: LocationListScreen(),
    );
  }
}

Future<Position> _determinePosition() async {
  bool serviceEnabled;
  LocationPermission permission;

  // Test if location services are enabled.
  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    // Location services are not enabled don't continue
    // accessing the position and request users of the
    // App to enable the location services.
    return Future.error('Location services are disabled.');
  }

  permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      // Permissions are denied, next time you could try
      // requesting permissions again (this is also where
      // Android's shouldShowRequestPermissionRationale
      // returned true. According to Android guidelines
      // your App should show an explanatory UI now.
      return Future.error('Location permissions are denied');
    }
  }

  if (permission == LocationPermission.deniedForever) {
    // Permissions are denied forever, handle appropriately.
    return Future.error(
        'Location permissions are permanently denied, we cannot request permissions.');
  }

  // When we reach here, permissions are granted and we can
  // continue accessing the position of the device.
  return await Geolocator.getCurrentPosition();
}

class LocationListScreen extends StatefulWidget {
  @override
  _LocationListScreenState createState() => _LocationListScreenState();
}

class _LocationListScreenState extends State<LocationListScreen> {
  final String mainUrl =
      "https://maps.umd.edu/arcgis/rest/services/Layers/CampusServices/MapServer/0";
  List<List<dynamic>> subUrls = [];
  double getLatitude(Coordinates? addressLocation) {
    return addressLocation?.latitude ?? 0.0;
  }

  double getLongitude(Coordinates? addressLocation) {
    return addressLocation?.longitude ?? 0.0;
  }

  Future<List<double>> getLatLong(String address) async {
    double lat = 0.0;
    double long = 0.0;
    // Query the locations table to find a row with the specified address
    final response = await Supabase.instance.client
        .from('bathroom_data')
        .select()
        .eq('address', address);
    final locations = response;

    if (locations.isNotEmpty) {
      // If a matching location is found, check if it has valid latitude and longitude values
      final location = locations.first;
      print("Location was not empty!");
      return [location['latitude'], location['longitude']];
    } else {
      // If the location does not have valid latitude and longitude values, use the geocode package to get them
      List<GBSearchData> data = await GeocoderBuddy.query(address);
      if (data.isEmpty) {
        print("address not found");
        lat = 0.0;
        long = 0.0;
      } else {
        lat = double.parse(data[0].lat);
        long = double.parse(data[0].lon);
      }
      // Update the location in the database with the new latitude and longitude values
      await Supabase.instance.client.from('bathroom_data').update({
        'latitude': lat,
        'longitude': long,
      }).eq('address', address);

      return [lat, long];
    }
  }

  Future<void> fetchSubUrls() async {
    subUrls.clear();
    Position position = await _determinePosition();

    // Construct an array of URLs to fetch
    List<String> urls = [];
    for (int i = 1; i < 145; i++) {
      final url = Uri.parse('$mainUrl/$i?f=json').toString();
      urls.add(url);
    }

    // Query the locations table to find rows with URLs that match the URLs being fetched
    final locations =
        await Supabase.instance.client.from('bathroom_data').select("url");
    // Fetch data for each URL that is not already in the database
    for (final url in urls) {
      if (locations.isEmpty ||
          !locations.any((location) => location['url'] == url)) {
        print(url);
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && !response.body.contains("Invalid")) {
          final json = jsonDecode(response.body);
          final address = json["feature"]["attributes"]["ADDRESS"];
          final buildingName = json["feature"]["attributes"]["BUILDINGNAME"];
          final roomNum = json["feature"]["attributes"]["ROOM_NUM"];
          List<double> latLong = await getLatLong(address);
          double distanceInMeters = await Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            latLong[0],
            latLong[1],
          );
          double distanceInMiles = distanceInMeters / 1609.34;
          final desc = [
            address,
            buildingName + ", Room " + roomNum,
            "${distanceInMiles.toStringAsFixed(2)} mi"
          ];

          // Insert the new URL into the database
          await Supabase.instance.client.from('bathroom_data').insert({
            'url': url,
            'address': address,
            'building_name': buildingName,
            'room_num': roomNum,
            'latitude': latLong[0],
            'longitude': latLong[1],
          });

          subUrls.add(desc);
        }
      }
    }

    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    fetchSubUrls();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Location List'),
      ),
      body: ListView.builder(
        itemCount: subUrls.length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text(subUrls[index][1]),
            subtitle: Text(subUrls[index][0]),
            trailing: Text(subUrls[index][2]),
          );
        },
      ),
    );
  }
}
