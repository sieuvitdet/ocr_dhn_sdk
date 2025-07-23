import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class GetNumberOCR {
  final String apiUrl = 'https://super-agent-api.meobeo.ai/water-clock-ocr';

  Future<String?> ocrImage(File imageFile) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse(apiUrl));
      request.files.add(
        await http.MultipartFile.fromPath('image', imageFile.path),
      );

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status_code'] == 0 &&
            data['data'] != null &&
            data['data']['success'] == true) {
          return data['data']['result'] as String;
        }
        return null;
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }
}