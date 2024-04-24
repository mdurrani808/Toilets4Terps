import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geocoder_buddy/geocoder_buddy.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_fonts/google_fonts.dart'; // Add this line.
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

String? userId;
void main() async {
  // setup Supabase w/ project URL and API key
  // TODO: probably deal with the API key better...
  WidgetsFlutterBinding.ensureInitialized();
  userId = await getUserIdFromLocalStorage();
  if (userId == null) {
    // No user ID found, generate a new one
    userId = const Uuid().v1();

    // Save to storage for next time
    saveUserIdToLocalStorage();
  } else {
    // User ID found, use it
    userId = userId.toString();
  }

  await Supabase.initialize(
      url: '',
      anonKey:
          '',
      headers: {
        "Access-Control-Allow-Origin": "*",
      });

  runApp(const MyApp());
}

// basic app with a single screen
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nearest Bathrooms',
      theme: ThemeData(
        textTheme: GoogleFonts.montserratTextTheme(),
        primarySwatch: Colors.red,
        useMaterial3: true,
      ),
      home: const LocationListScreen(),
    );
  }
}

// Call this on initState and assign to userId variable
/* 
  This function is used to get the current location of the user.
  It is used to calculate the distance between the user and the
  bathrooms in the database.
*/
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

Future<void> saveUserIdToLocalStorage() async {
  const storage = FlutterSecureStorage();
  await storage.write(key: 'userId', value: userId);
}

Future<String?> getUserIdFromLocalStorage() async {
  const storage = FlutterSecureStorage();
  return storage.read(key: 'userId');
}

// Call this on initState and assign to userId variable

// Call this on initState after generating the ID
/// This screen displays a list of bathrooms that are in the database.
class LocationListScreen extends StatefulWidget {
  const LocationListScreen({super.key});

  @override
  _LocationListScreenState createState() => _LocationListScreenState();
}

class _LocationListScreenState extends State<LocationListScreen> {
  //main url that all the bathrooms come from (right now only gender neutral/private bathrooms)
  final String mainUrl =
      "https://maps.umd.edu/arcgis/rest/services/Layers/CampusServices/MapServer/0";
  // list that stores all the JSON urls for the bathrooms and their data (probably not needed anymore)
  //TODO: refactor
  List<List<dynamic>> subUrls = [];
  double currentRating = 0.0;
  //Given an address, finds the latitude and longitude of the address
  Future<List<double>> getLatLong(String address) async {
    double lat = 0.0;
    double long = 0.0;
    // Query the locations table to find a row with the specified address
    //gets a row that has the given address
    final locations = await Supabase.instance.client
        .from('bathroom_data')
        .select()
        .eq('address', address);

    if (locations.isNotEmpty) {
      // If a matching location is found, check if it has valid latitude and longitude values
      final location = locations.first;
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

  Future<void> updateDatabase() async {
    // Construct an array of URLs to fetch
    List<String> urls = [];
    //todo: find a better way to iterate through rather than just setting an arbitrary limit like 145
    for (int i = 1; i < 145; i++) {
      final url = Uri.parse('$mainUrl/$i?f=json').toString();
      urls.add(url);
    }

    //Get a list of all the urls that are already in the database
    final locations =
        await Supabase.instance.client.from('bathroom_data').select("url");

    // Fetch data for each URL that is not already in the database
    for (final url in urls) {
      //if the location is empy or there is already a row for that url
      //TODO: do this based off of address and not URL (may not be deterministic?)
      if (locations.isEmpty ||
          !locations.any((location) => location['url'] == url)) {
        print(url);
        //get the json, and calculate/parse out relevant fields
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && !response.body.contains("Invalid")) {
          final json = jsonDecode(response.body);
          final address = json["feature"]["attributes"]["ADDRESS"];
          final buildingName = json["feature"]["attributes"]["BUILDINGNAME"];
          final roomNum = json["feature"]["attributes"]["ROOM_NUM"];
          List<double> latLong = await getLatLong(address);

          // Insert the new row into the database
          await Supabase.instance.client.from('bathroom_data').insert({
            'url': url,
            'address': address,
            'building_name': buildingName,
            'room_num': roomNum,
            'latitude': latLong[0],
            'longitude': latLong[1],
          });
        }
      }
    }
  }

  Future<Map<String, double>> getDistances() async {
    Position position = await _determinePosition();

    // Create a map to store the distances
    Map<String, double> distances = {};

    // Get all rows from the database
    final locations =
        await Supabase.instance.client.from('bathroom_data').select();
    for (final location in locations) {
      double distanceInMeters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        location['latitude'],
        location['longitude'],
      );
      double distanceInMiles = distanceInMeters / 1609.34;
      distances[location['address']] = distanceInMiles;
    }
    return distances;
  }

  @override
  void initState() {
    super.initState();
    // Check if we already have a user ID

    updateDatabase();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, double>>(
      future: getDistances(),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          Map<String, double>? distances = snapshot.data;
          return Scaffold(
            appBar: AppBar(title: const Text('Nearest Bathrooms'), actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  getDistances();
                },
              )
            ]),
            body: FutureBuilder<List<Map<String, dynamic>>>(
              future: Supabase.instance.client.from('bathroom_data').select(),
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return createExpansionTiles(snapshot, distances);
                } else if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                } else {
                  return const Center(child: CircularProgressIndicator());
                }
              },
            ),
          );
        } else if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }

  Future<double?> getRatingForBathroom(
    String buildingName,
    String roomNum,
    String userId,
  ) async {
    final result = await Supabase.instance.client
        .from('reviews')
        .select('rating')
        .eq('device_id', userId)
        .eq('building_name', buildingName)
        .eq('room_num', roomNum);
    if (result.isEmpty) {
      return 1;
    } else {
      return result.first['rating'];
    }
  }

  // Function to update the bathroom rating in the database
  Future<void> updateBathroomRatingInDatabase(
      String userId, double rating, String buildingName, String roomNum) async {
    final existing = await Supabase.instance.client
        .from('bathroom_data')
        .select()
        .eq('user_id', userId)
        .eq('building_name', buildingName)
        .eq('room_num', roomNum);

    if (existing.isEmpty) {
      // Insert new row with user id
      await Supabase.instance.client.from('bathroom_data').insert({
        'user_id': userId,
        'building_name': buildingName,
        'room_num': roomNum,
        'rating': rating
      });
    } else {
      // Update existing row for user
      await Supabase.instance.client
          .from('bathroom_data')
          .update({'rating': rating})
          .eq('user_id', userId)
          .eq('building_name', buildingName)
          .eq('room_num', roomNum);
    }
  }

  ListView createExpansionTiles(
      AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
      Map<String, double>? distances) {
    List<Map<String, dynamic>>? locations = snapshot.data;
    // Sort the locations by distance in miles
    locations?.sort((a, b) => (distances?[a['address']] ?? 0)
        .compareTo(distances?[b['address']] ?? 0));
    List<Widget> expansionTiles = [];
    for (int index = 0; index < locations!.length; index++) {
      Map<String, dynamic> location = locations[index];
      String address = location['address'];
      int id = location['id'];
      String buildingName = location['building_name'];
      String roomNum = location['room_num'];
      double rating = location['rating'];
      double? distanceInMiles = distances![address];
      // Generate a Google Maps link for the address
      String googleMapsLink =
          'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}';

      // Define a separate RatingBar widget for each bathroom
      RatingBar ratingBar = RatingBar.builder(
        initialRating: rating,
        minRating: 1,
        itemCount: 5,
        direction: Axis.horizontal,
        allowHalfRating: false,
        itemBuilder: (context, _) => const Icon(
          Icons.star,
          color: Colors.amber,
        ),
        onRatingUpdate: (newRating) {
          // Update the rating for this specific bathroom in the database
          updateBathroomRatingInDatabase(
              userId!, rating, buildingName, roomNum);
        },
      );

      // Create an ExpansionTile for each bathroom
      expansionTiles.add(ExpansionTile(
        title: Text('$buildingName, Room $roomNum'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Rating pill
            FutureBuilder(
                future: getRatingForBathroom(buildingName, roomNum, userId!),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    double? rating = snapshot.data;

                    if (rating != -1) {
                      // Only show if rating is not null
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8.0, vertical: 4.0),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                                width:
                                    4.0), // Add space between the icon and text
                            Text(
                              '${rating?.toStringAsFixed(1)} / 5',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      );
                    } else {
                      return const SizedBox(); // Rating is null, show nothing
                    }
                  } else {
                    return const SizedBox(); // Loading
                  }
                }),
            const SizedBox(width: 8.0), // Add space between the two pills

            // Distance pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
              decoration: BoxDecoration(
                color: Colors.blue,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 4.0), // Add space between the icon and text
                  Text(
                    '${distanceInMiles?.toStringAsFixed(2)} mi',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
        children: [
          // Additional information about the bathroom can be added here
          // You can display any other details you have in this section
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                          20), // This gives the button rounded edges
                    ),
                  ),
                  icon: const Icon(Icons.map), // This adds a map icon before the text
                  label: const Text(''),
                  onPressed: () {
                    // Open the Google Maps link when the button is clicked
                    launchUrl(Uri.parse(googleMapsLink));
                  },
                ),
              ),
              const SizedBox(width: 8.0), // Add space between the two buttons
              Expanded(
                child: ElevatedButton.icon(
                  icon:
                      const Icon(Icons.star), // This adds a star icon before the text
                  style: ElevatedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                          20), // This gives the button rounded edges
                    ),
                  ),
                  label: const Text(''),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (BuildContext context) {
                        return AlertDialog(
                          content: ratingBar,
                          actions: [
                            TextButton(
                              child: const Text('Submit Rating'),
                              onPressed: () {
                                updateBathroomRatingInDatabase(
                                    userId!, rating, buildingName, roomNum);
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          )
        ],
      ));
    }

    return ListView(
      children: expansionTiles,
    );
  }
}
