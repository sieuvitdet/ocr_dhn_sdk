class ImageExternalStorage {

  static Future saveToDocument(Uint8List image, {int quality = 85, String? onlineVal, String? localVal}) async {
  try {
    final mobiXImagesDirectory = await getMobiXImagesDirectory();
    final DateTime now = DateTime.now();
    final String fileName = 'obb_online_${onlineVal}_local_$localVal.jpg';
    final String targetPath = '${mobiXImagesDirectory.path}/$fileName';
    String newPath = targetPath;

    // Kiểm tra nếu file đã tồn tại, thêm số thứ tự phía sau
    File targetFile = File(targetPath);
    if (await targetFile.exists()) {
      int counter = 1;
      do {
        newPath = '${mobiXImagesDirectory.path}/obb_online_${onlineVal}_local_${localVal}_$counter.jpg';
        targetFile = File(newPath);
        counter++;
      } while (await targetFile.exists());
    }

    final event = await FlutterImageCompress.compressWithList(
        image,
        quality: quality,
      );
      targetFile.writeAsBytesSync(event);
  } catch (e) {
    print('Lỗi khi lưu ảnh: $e');
    return null;
  }
}

  static Future<Directory> getMobiXImagesDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final mobiXImagesDirectory = Directory('${directory.path}/documents/images');

    // Tạo thư mục nếu chưa tồn tại
    if (!await mobiXImagesDirectory.exists()) {
      await mobiXImagesDirectory.create(recursive: true);
    }

    return mobiXImagesDirectory;
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobinet_core/common/lang_key.dart';
import 'package:mobinet_core/common/localization/app_localizations.dart';
import 'package:mobinet_core/common/theme.dart';
import 'package:mobinet_core/common/utils/custom_navigator.dart';
import 'package:mobinet_core/common/utils/extension.dart';
import 'package:mobinet_core/common/utils/image_external_storage.dart';
import 'package:mobinet_core/common/widget/widget.dart';
import 'package:mobinet_core/data/model/base/menu_model.dart';
import 'package:mobinet_core/presentation/module/main_module/main/module/image_storage/bloc/image_document_cache_bloc.dart';
import 'package:path/path.dart' as path;

class ImageDocumentCacheScreen extends StatefulWidget {
  final String? contract;
  ImageDocumentCacheScreen({this.contract});

  @override
  _ImageDocumentCacheScreenState createState() =>
      _ImageDocumentCacheScreenState();
}

class _ImageDocumentCacheScreenState extends State<ImageDocumentCacheScreen>
    with SingleTickerProviderStateMixin {
  late ImageDocumentCacheBloc _bloc;
  bool _isZoom = false;

  @override
  void initState() {
    super.initState();
    _bloc = ImageDocumentCacheBloc(context);
    _bloc.menuSelected = _bloc.menuFilter[1];
    _bloc.streamMenu.set(_bloc.menuFilter);
    _loadImages();

    _animationController =
        AnimationController(vsync: this, duration: Duration(milliseconds: 300))
          ..addListener(() {
            _controller.value = _animation.value;
          });

    _controller.addListener(() {
      bool isInteractive = _controller.value.storage[10] > 1;
      if (!_isZoom) {
        if (isInteractive) {
          setState(() {
            _isZoom = true;
          });
        }
      } else {
        if (!isInteractive) {
          setState(() {
            _isZoom = false;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _dismissCurrentOverlay();
    _controller.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadImages() async {
    setState(() => _bloc.isLoading = true);
    try {
      final images = await getAllMobiXImages();

      // Nhóm ảnh theo ngày
      final groupedImages = _bloc.groupImagesByDate(images, contract: (_bloc.menuSelected.type == 0) ? null : widget.contract);

      setState(() {
        _bloc.imageFiles = images;
        _bloc.groupedImages = groupedImages;
        _bloc.isLoading = false;
      });
    } catch (e) {
      setState(() => _bloc.isLoading = false);
      print('Lỗi khi tải hình ảnh: $e');
    }
  }

  Future<List<File>> getAllMobiXImages() async {
    try {
      final documentImagesDirectory =
          await ImageExternalStorage.getDocumentImagesDirectory();

      final List<FileSystemEntity> entities =
          await documentImagesDirectory.list().toList();

      // Lọc ra chỉ các file ảnh
      final List<File> imageFiles = entities
          .whereType<File>()
          .where((file) => ['.jpg', '.jpeg', '.png', '.gif', '.webp']
              .any((ext) => file.path.toLowerCase().endsWith(ext)))
          .toList();

      return imageFiles;
    } catch (e) {
      print('Lỗi khi lấy danh sách ảnh từ mobiX: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => _loadImages(),
      child: CustomScaffold(
        title: "Quản lý hình ảnh IQC",
        body: _bloc.isLoading
            ? Center(child: CircularProgressIndicator())
            : _bloc.imageFiles == null || _bloc.imageFiles!.isEmpty
                ? Center(child: Text('Không có hình ảnh nào'))
                : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_bloc.groupedImages == null || _bloc.groupedImages!.isEmpty) {
      return Center(child: CustomText(text: 'Không có hình ảnh nào', fontStyle: FontStyle.italic,color: AppColors.black,));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Container(
        //           decoration: BoxDecoration(
        //             color: AppColors.white,
        //             border: Border.all(color: AppColors.greyHint),
        //             borderRadius: BorderRadius.circular( AppSizes.small),
        //           ),
        //           child: CustomSearch(
        //             prefixIcon: true,
        //             hintText: "Nhập số hợp đồng để tìm kiếm.",
        //             controller: _bloc.controllerSearch,
        //             focusNode: _bloc.focusSearch,
        //             onChanged: (val) {
        //               if (val.isNotEmpty) {
        //                   _bloc.searchImagebyContract(val);
        //                 }
        //             },
        //             prefixIconColor: AppColors.black,
        //           )),
        Padding(
          padding: EdgeInsets.only(left: AppSizes.regular,bottom: AppSizes.extraSmall),
          child: CustomText(text: "*Nhấn ảnh để chọn.", fontStyle: FontStyle.italic,),
        ),
        Padding(
          padding: EdgeInsets.only(left: AppSizes.regular,bottom: AppSizes.extraSmall),
          child: CustomText(text: "*Nhấn giữ ảnh để xem lại.", fontStyle: FontStyle.italic,),
        ),
         _buildFilter(),
        Expanded(
            child: CustomScrollView(
          slivers: _buildDateGroupedSlivers(),
        )),
      ],
    );
  }

  List<Widget> _buildDateGroupedSlivers() {
    final List<Widget> slivers = [];

    for (final group in _bloc.groupedImages!) {
      // Thêm header ngày
      slivers.add(
        SliverToBoxAdapter(
          child: _buildDateHeader(group.date),
        ),
      );

      // Thêm grid hình ảnh cho ngày này
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 8.0),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.0,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                return _buildImageItem(group.images[index]);
              },
              childCount: group.images.length,
            ),
          ),
        ),
      );

      // Thêm separator giữa các nhóm ngày
      slivers.add(
        SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
      );
    }

    return slivers;
  }

  Widget _buildDateHeader(DateTime date) {
    final String formattedDate =
        DateFormat('EEEE, dd MMMM, yyyy', 'vi_VN').format(date);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppSizes.regular, vertical: AppSizes.semiRegular),
      color: AppColors.transparent,
      child: Row(
        children: [
          CustomText(
            text: formattedDate,
            style: TextStyle(
              fontSize: AppTextSizes.extraBody,
              fontWeight: FontWeight.bold,
              color: AppColors.blue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageItem(File file) {
    final String fileName = path.basename(file.path);
    final String? contractId = _bloc.extractContractId(fileName) ?? "";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
            child: GestureDetector(
                onTap: () => CustomNavigator.pop(context, object: file.readAsBytesSync()),
                onLongPress: () => _showImagePreview(context, file),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          file,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => _deleteImage(file),
                        child: Container(
                          padding: EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppColors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.delete,
                            color: AppColors.red,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ))),
        Gaps.vGap4,
        CustomText(
            text: contractId,
            style: TextStyle(
              color: AppColors.black,
              fontWeight: FontWeight.bold,
              fontSize: AppTextSizes.body,
            ))
      ],
    );
  }

  Future _deleteImage(File file) async {
    CustomNavigator.showCustomPopupAction(
        showCloseIcon: false,
        context,
        AppLocalizations.text(LangKey.confirm),
        content: "Bạn có chắc muốn xóa hình ảnh này?",
        textAlign: TextAlign.center, onConfirm: () async {
      CustomNavigator.pop(context);
      await file.delete();
      _loadImages();
    }, onClose: () {
      CustomNavigator.pop(context);
    });
  }


  Widget _buildFilter() {
    return StreamBuilder(
      stream: _bloc.streamMenu.output,
      initialData: _bloc.menuFilter,
      builder: (context, snapshot) {
        _bloc.menuFilter = snapshot.data ?? [];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: EdgeInsets.only(left: AppSizes.semiRegular,right: AppSizes.small),
              child: CustomText(
                text: "Lọc theo",
                color: AppColors.black,
                fontWeight: FontWeight.w700,
              ),
            ),
        
            Expanded(child: Container(
                      height: 32,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: _bloc.menuFilter.map((e) => _buildFilterItem(e)).toList(),
                      ),
                    )),
            //  Divider(thickness: 1, height: 30),
          ],
        );
      }
    );
  }

  Widget _buildFilterItem(MenuModel model) {
    return InkWell(
      onTap: () {
        _bloc.onTapFilter(model);
        _loadImages();
      },
      child: Padding(
        padding: EdgeInsets.only(right: AppSizes.regular),
        child: Row(
            children: [
              Icon(
                model.enable ? Icons.radio_button_checked : Icons.radio_button_off_rounded,
                color: model.enable ? AppColors.primary : AppColors.gray,
                size: 20,
              ),
              Gaps.hGap4,
              CustomText(text: model.text ?? ""),
            ],
          ),
      ),
    );
  }

  OverlayEntry? _currentOverlay;
  late TapDownDetails _details;

  late AnimationController _animationController;
  late Animation<Matrix4> _animation;
  final TransformationController _controller = TransformationController();

  void _showImagePreview(BuildContext context, File imageFile) {
    // Loại bỏ overlay hiện tại nếu có
    _dismissCurrentOverlay();

    // Lấy kích thước màn hình
    final Size screenSize = MediaQuery.of(context).size;

    // Tọa độ trung tâm màn hình
    final double centerX = screenSize.width / 2;
    final double centerY = screenSize.height / 2;

    // Kích thước và vị trí của overlay image
    final double previewWidth = screenSize.width * 0.8;
    final double previewHeight = screenSize.height * 0.6;
    final double leftPosition = centerX - previewWidth / 2;
    final double topPosition = centerY - previewHeight / 2;

    // Tạo overlay entry mới
    _currentOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Layer phủ toàn màn hình, để xử lý sự kiện tap ngoài ảnh
          Positioned.fill(
            child: GestureDetector(
                onTap: _dismissCurrentOverlay,
                child: Container(
                  color: AppColors.black.withOpacity(0.7),
                )),
          ),
          // Hiển thị ảnh preview ở giữa màn hình với kích thước cố định
          Positioned(
            left: leftPosition,
            top: topPosition,
            width: previewWidth,
            height: previewHeight,
            child: Material(
              elevation: 8.0,
              borderRadius: BorderRadius.circular(12),
              color: AppColors.black,
              clipBehavior: Clip.antiAlias,
              child: GestureDetector(
                  onDoubleTapDown: (details) => _details = details,
                  onDoubleTap: _doubleTap,
                  child: InteractiveViewer(
                      transformationController: _controller,
                      clipBehavior: Clip.none,
                      scaleEnabled: true,
                      panEnabled: true,
                      minScale: 1,
                      maxScale: 3,
                      child: Image.file(
                        imageFile,
                        fit: BoxFit.contain,
                        width: previewWidth,
                        height: previewHeight,
                      ))),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () async {
                    await imageFile.delete();
                    _dismissCurrentOverlay();
                    _loadImages();
                  },
                  child: Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.delete_outline,
                      color: AppColors.red,
                      size: 40,
                    ),
                  ),
                ),
                Gaps.hGap14,
                GestureDetector(
                  onTap: () async {
                    await Navigator.of(context)
                      ..pop
                      ..pop(imageFile.readAsBytesSync());
                  },
                  child: Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check,
                      color: AppColors.green,
                      size: 40,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // Hiển thị overlay
    Overlay.of(context).insert(_currentOverlay!);
  }

  _doubleTap() {
    final position = _details.localPosition;

    final double scale = 3;
    final x = -position.dx * (scale - 1);
    final y = -position.dy * (scale - 1);
    final zoomed = Matrix4.identity()
      ..translate(x, y)
      ..scale(scale);
    final value = _controller.value.isIdentity() ? zoomed : Matrix4.identity();

    _animation = Matrix4Tween(begin: _controller.value, end: value).animate(
        CurveTween(curve: Curves.easeOut).animate(_animationController));

    _animationController.forward(from: 0);
  }

  void _dismissCurrentOverlay() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}



  await ImageExternalStorage.saveToMobiX(imageBytes, value);
