package com.gicek.kakey.android.ui.add

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.gicek.kakey.android.R
import com.gicek.kakey.android.core.Core
import com.gicek.kakey.android.core.ParsedOtpAuth
import com.gicek.kakey.android.core.UiText
import com.gicek.kakey.android.core.text
import com.gicek.kakey.android.core.toParsed
import com.gicek.kakey.android.platform.QrImageDecoder
import com.gicek.kakey.android.ui.main.LocalNavigator
import com.gicek.kakey.android.ui.main.Route
import com.google.zxing.PlanarYUVLuminanceSource
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * QR code scanning: full-screen camera with a viewfinder (CameraX + ZXing, recognized on device). Google migration codes
 * split across several QR codes are collected one by one, showing "Scanned x / n", and go to the review page once complete.
 * Camera permission is requested only on entering this screen; if denied, the user is guided to system settings.
 */
@Composable
fun ScannerScreen() {
    val context = LocalContext.current
    val navigator = LocalNavigator.current
    val addFlow = LocalAddFlow.current
    val view = LocalView.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var denied by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<UiText>(UiText.Res(R.string.point_the_camera_at_the_qr)) }
    var cameraError by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok
        denied = !ok
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }

    // Collect Google migration batches: deduplicate within a batch by batchKey and submit once complete
    val collected = remember { linkedMapOf<String, List<ParsedOtpAuth>>() }
    var activeBatch by remember { mutableStateOf<Long?>(null) }
    var finished by remember { mutableStateOf(false) }

    fun finish(items: List<ParsedOtpAuth>) {
        if (finished) return
        finished = true
        navigator.pop()
        navigator.push(Route.Review(items))
    }

    fun handle(payload: String) {
        if (finished) return
        val result = Core.parseScan(payload, Core.placeholders(context))
        val accounts = result.accounts.map { it.toParsed() }
        if (accounts.none { it.isValid }) {
            status = UiText.Res(R.string.not_a_valid_2fa_qr_code)
            return
        }
        view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        val size = result.batchSize ?: 1
        val key = result.batchKey
        if (!result.isGoogleMigration || size <= 1 || key == null) {
            finish(accounts)
            return
        }
        if (activeBatch != result.batchId) {
            activeBatch = result.batchId
            collected.clear()
        }
        collected[key] = accounts
        status = UiText.Res(R.string.scanned_google_migration_qr_x_x, collected.size, size)
        if (collected.size >= size) finish(collected.keys.sorted().flatMap { collected[it].orEmpty() })
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (granted && !cameraError) {
            CameraPreview(onCode = ::handle, onError = { cameraError = true })
            Box(
                Modifier
                    .align(Alignment.Center)
                    .size(260.dp)
                    .border(BorderStroke(3.dp, Color.White.copy(alpha = 0.9f)), RoundedCornerShape(28.dp)),
            )
        } else {
            Column(
                Modifier.align(Alignment.Center).padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    stringResource(if (cameraError) R.string.cant_open_the_camera else R.string.camera_access_is_needed_to_scan),
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
                if (denied) {
                    Button(onClick = {
                        context.startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                        )
                    }) { Text(stringResource(R.string.open_settings)) }
                }
            }
        }
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            IconButton(
                onClick = navigator::pop,
                colors = IconButtonDefaults.iconButtonColors(containerColor = Color.Black.copy(alpha = 0.4f), contentColor = Color.White),
                modifier = Modifier.padding(8.dp),
            ) { Icon(Icons.Outlined.Close, contentDescription = stringResource(R.string.cancel)) }
        }
        Column(
            Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(shape = CircleShape, color = Color.Black.copy(alpha = 0.55f), contentColor = Color.White) {
                Text(
                    status.text(),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
            FilledTonalButton(onClick = {
                navigator.pop()
                addFlow.pickPhotos()
            }) {
                Icon(Icons.Outlined.PhotoLibrary, null, Modifier.size(18.dp))
                Text(stringResource(R.string.choose_from_photos), Modifier.padding(start = 8.dp))
            }
        }
    }
}

/**
 * Camera preview and frame capture. Recognition runs on a separate analysis thread, so the "last code" used for
 * deduplication is an [AtomicReference] rather than Compose state. Camera provider callbacks may arrive after the screen has
 * left; an [AtomicBoolean] tracks whether it is still active, and after leaving nothing is bound or called back.
 */
@Composable
private fun CameraPreview(onCode: (String) -> Unit, onError: () -> Unit) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    val lastPayload = remember { AtomicReference<String?>(null) }

    DisposableEffect(lifecycle) {
        val active = AtomicBoolean(true)
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (!active.get()) return@addListener
            try {
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { analysis ->
                        analysis.setAnalyzer(executor) { image ->
                            val payload = try {
                                decode(image)
                            } finally {
                                image.close()
                            }
                            // Handle a code recognized repeatedly in a row only once; drop it if the screen has left
                            if (payload != null && active.get() && lastPayload.getAndSet(payload) != payload) {
                                ContextCompat.getMainExecutor(context).execute { if (active.get()) onCode(payload) }
                            }
                        }
                    }
                provider.unbindAll()
                provider.bindToLifecycle(lifecycle, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (error: Exception) {
                if (active.get()) onError()
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose {
            active.set(false)
            if (future.isDone) runCatching { future.get().unbindAll() }
            executor.shutdown()
        }
    }
    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
}

/** Recognizes from the luminance plane only, avoiding a full-frame conversion. */
private fun decode(image: ImageProxy): String? {
    val plane = image.planes.firstOrNull() ?: return null
    val buffer = plane.buffer
    val data = ByteArray(buffer.remaining()).also(buffer::get)
    val source = PlanarYUVLuminanceSource(data, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
    return QrImageDecoder.decode(source).firstOrNull()
}
