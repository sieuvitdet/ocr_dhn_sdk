package com.waterclockdetection

import android.graphics.Bitmap
import android.graphics.Color
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class TestImageAdapter(
    private val items: List<TestImageItem>,
    private val onImageSelected: (TestImageItem) -> Unit
) : RecyclerView.Adapter<TestImageAdapter.ViewHolder>() {

    private var selectedPosition: Int = -1

    data class TestImageItem(
        val fileName: String,
        val thumbnail: Bitmap
    )

    class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val thumbImageView: ImageView = view.findViewById(R.id.thumbImageView)
        val thumbLabel: TextView = view.findViewById(R.id.thumbLabel)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_test_image, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        val item = items[position]
        holder.thumbImageView.setImageBitmap(item.thumbnail)
        holder.thumbLabel.text = item.fileName

        // Highlight selected item
        if (position == selectedPosition) {
            holder.thumbImageView.setBackgroundColor(Color.parseColor("#1976D2"))
            holder.thumbImageView.setPadding(3, 3, 3, 3)
        } else {
            holder.thumbImageView.setBackgroundColor(Color.parseColor("#333333"))
            holder.thumbImageView.setPadding(0, 0, 0, 0)
        }

        holder.itemView.setOnClickListener {
            val prev = selectedPosition
            selectedPosition = holder.adapterPosition
            if (prev >= 0) notifyItemChanged(prev)
            notifyItemChanged(selectedPosition)
            onImageSelected(item)
        }
    }

    override fun getItemCount() = items.size
}
