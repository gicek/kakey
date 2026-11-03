package com.gicek.kakey.android.platform

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.PersistableBundle
import android.provider.Settings
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.BitMatrix
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.GenericMultipleBarcodeReader
import com.google.zxing.qrcode.QRCodeWriter

/**
 * Copies verification codes: the clip is marked sensitive (Android 13+ `EXTRA_IS_SENSITIVE`) so the system hides its content
 * in the clipboard preview. The system shows its own "copied" confirmation, so the app doesn't repeat it (Android 13+
 * guidelines).
 */
object Clipboard {
    fun copySensitive(context: Context, text: String) {
        val clip = ClipData.newPlainText("Kakey", text).apply {
            description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
        }
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    }

    fun text(context: Context): String? = context.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf {
        it.itemCount > 0
    }?.getItemAt(0)?.coerceToText(context)?.toString()
}

/** Device name (written to sync metadata and backup history; not sensitive). */
object DeviceInfo {
    fun name(context: Context): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) ?: android.os.Build.MODEL
}

/** Recognizes QR codes in images (ZXing, on device, nothing uploaded); one image may contain several codes. */
object QrImageDecoder {
    /** Very large photos are scaled down to fit this edge length first: faster, and still sharp enough. */
    private const val MAX_DECODE_EDGE = 2048
    private val hints = mapOf(
        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.ALSO_INVERTED to true,
    )

    fun decode(context: Context, uri: Uri): List<String> = runCatching {
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > MAX_DECODE_EDGE) decoder.setTargetSampleSize((longest + MAX_DECODE_EDGE - 1) / MAX_DECODE_EDGE)
        }
        decode(bitmap)
    }.getOrDefault(emptyList())

    fun decode(bitmap: Bitmap): List<String> {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return decode(RGBLuminanceSource(bitmap.width, bitmap.height, pixels))
    }

    fun decode(source: LuminanceSource): List<String> {
        val reader = GenericMultipleBarcodeReader(MultiFormatReader().apply { setHints(hints) })
        return runCatching { reader.decodeMultiple(BinaryBitmap(HybridBinarizer(source)), hints).mapNotNull { it.text } }
            .getOrDefault(emptyList())
            .distinct()
    }
}

/** Single-account QR code (generated on device by ZXing). */
object QrCodeImage {
    fun make(text: String, size: Int = 720): Bitmap {
        val matrix: BitMatrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 1))
        val pixels = IntArray(matrix.width * matrix.height) { index ->
            if (matrix.get(index % matrix.width, index / matrix.width)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()
        }
        return Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
    }
}
