import sys
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QCheckBox,
    QPushButton, QLabel, QComboBox, QSpinBox
)
from PyQt5.QtCore import QTimer
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg as FigureCanvas
from matplotlib.figure import Figure
import numpy as np
import cv2
from mss import mss
from matplotlib.patches import Circle

class PlotPanel(QMainWindow):
    def __init__(self,control_panel=None):
        super().__init__()
        self.setWindowTitle("Plot Panel")
        self.central_widget = QWidget(self)
        self.setCentralWidget(self.central_widget)
        self.layout = QVBoxLayout(self.central_widget)
        self.control_panel = control_panel
        # Initialize the Matplotlib figure
        self.figure = Figure()
        self.canvas = FigureCanvas(self.figure)
        self.layout.addWidget(self.canvas)

        self.axes = []  # List to store axes
        self.sct = mss()
        self.x, self.y, self.w, self.h = 20,20,20,20  # Extract ROI coordinates

    def set_control_panel(self, control_panel):
        self.control_panel = control_panel

    def closeEvent(self, event):
        """Close the control panel when this panel is closed."""
        if self.control_panel:
            self.control_panel.close()
        super().closeEvent(event)
    def update_layout(self, num_axes, arrangement="horizontal"):
        """Dynamically update the layout of the canvas."""
        self.figure.clear()
        self.axes = []

        if arrangement == "horizontal" and num_axes > 0:
            for i in range(num_axes):
                ax = self.figure.add_subplot(1, num_axes, i + 1)
                self.axes.append(ax)
        elif arrangement == "vertical" and num_axes > 0:
            for i in range(num_axes):
                ax = self.figure.add_subplot(num_axes, 1, i + 1)
                self.axes.append(ax)
        elif arrangement == "2x2" and num_axes > 0:
            for i in range(num_axes):
                ax = self.figure.add_subplot(2, 2, i + 1)
                self.axes.append(ax)

        self.canvas.draw()

    def plot_data(self, plot_types):
        screenshot = np.array(self.sct.grab(self.monitor))
        frame = cv2.cvtColor(screenshot, cv2.COLOR_BGRA2BGR)
        roi_frame = frame[self.y:self.y + self.h, self.x:self.x + self.w]
        """Plot specific data based on plot_types."""
        for ax, plot_type in zip(self.axes, plot_types):
            ax.clear()
            if plot_type == "Vectorscope YUV":
                self.plot_vectorscope(ax,roi_frame,plot_type)
            elif plot_type == "Vectorscope Color":
                self.plot_vectorscope(ax,roi_frame,plot_type)
            elif plot_type == "Waveform Luma":
                self.plot_waveform(ax, roi_frame, plot_type)
            elif plot_type == "RGB Parade":
                self.plot_waveform(ax, roi_frame, plot_type)
            elif plot_type == "Waveform RGB":
                self.plot_waveform(ax, roi_frame, plot_type)
        self.canvas.draw()

    def take_screenshot(self):
        """Take a screenshot of the plot panel and save it as an image."""
        # Take a screenshot using pyautogui
        self.sct = mss()
        self.monitor = self.sct.monitors[self.control_panel.activeScreen]  # Use activeScreen for monitor selection

        screenshot = np.array(self.sct.grab(self.monitor))      
        frame = cv2.cvtColor(screenshot, cv2.COLOR_BGRA2BGR)
        # Let user select the ROI
        roi = cv2.selectROI("Select Region of Interest", frame, False, False)
        cv2.destroyWindow("Select Region of Interest")
        self.x, self.y, self.w, self.h = map(int, roi)  # Extract ROI coordinates
        if self.control_panel:
            self.control_panel.refresh_plot()
            self.control_panel.refresh_plot()
        
    def calculate_luminance_waveform(self,frame):

        gray_image = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        # Get the image dimensions
        _, width = gray_image.shape

        # Initialize an array to store the waveform
        waveform = np.zeros((255, width), dtype=np.uint8)  # 256 for luminance levels (0-255)
        # Convert the grayscale image to IRE
        # Process each column to generate the waveform
        for x in range(width):
            column = gray_image[:, x]

            hist, _ = np.histogram(column, bins=255, range=(0,256))
            normalized_hist = (hist / hist.max() * 255).astype(np.uint8) if hist.max() > 0 else hist
            for y, value in enumerate(normalized_hist):
                     waveform[254-y, x] = value  # Flip vertically for correct orientation
        
        return waveform

    def calculate_rgb_waveform(self, frame, type):
        _, width,_ = frame.shape
        frame = frame[:, :, [2, 1, 0]]
        if type == "RGB Parade":
            waveform = np.zeros((255, width * 3, 3), dtype=np.uint8)  # RGB side by side

            for x in range(width):
                for channel in range(3):
                    column = frame[:, x, channel]
                    hist, _ = np.histogram(column, bins=255, range=(0, 256))
                    normalized_hist = (hist / hist.max() * 255).astype(np.uint8) if hist.max() > 0 else hist
                    for y, value in enumerate(normalized_hist):
                        waveform[254 - y, x + channel * width, channel] = value
        elif type == "Waveform RGB":
            waveform = np.zeros((255, width, 3), dtype=np.uint8)

            for x in range(width):
                for channel in range(3):
                    column = frame[:, x, channel]
                    hist, _ = np.histogram(column, bins=255, range=(0, 256))
                    normalized_hist = (hist / hist.max() * 255).astype(np.uint8) if hist.max() > 0 else hist
                    for y, value in enumerate(normalized_hist):
                        waveform[254 - y, x, channel] = value  #
            

        return waveform

    def calculate_YUV_values(self,frame):
        # Load the image and convert to YUV
        #image = Image.open(image_path)
        #image_np = np.array(image)
        #image_yuv = cv2.cvtColor(image_np, cv2.COLOR_RGB2YUV)
        yuv = cv2.cvtColor(frame, cv2.COLOR_BGR2YUV)
        # Normalize U and V channels
        U = yuv[:, :, 1].flatten() / 255.0 * 2 - 1
        V = yuv[:, :, 2].flatten() / 255.0 * 2 - 1
        rgb = frame[:, :, ::-1].reshape(-1, 3) / 255.0  # Swap channels and normalize to [0, 1]
        #bins = 1000  # Number of bins
        #hist, x_edges, y_edges = np.histogram2d(U, V, bins=bins, range=[[-1, 1], [-1, 1]])
        
        #hist = hist / np.max(hist)
        return U,V, rgb

    def plot_vectorscope(self,ax,frame,type):
        U,V, rgb = self.calculate_YUV_values(frame)
        color_points = {
        "B": (0.87, -0.19),
        "Mg": (0.56, 1),
        "R": (-0.28, 1),
        "Yl": (-0.87, 0.19),
        "G": (-0.56, -1),
        "Cy": (0.28, -1)
        }
        flesh_angle = 123  # Approximate angle of the flesh line in degrees
        flesh_rad = np.radians(flesh_angle)
        x_flesh, y_flesh = np.cos(flesh_rad), np.sin(flesh_rad)

        ax.plot([0, x_flesh], [0, y_flesh], color='red', linestyle='-', linewidth=1.2, alpha=0.5)

        for radius in [0.5, 0.75, 1.0]:
            circle = Circle((0, 0), radius, color='gray', fill=False, linestyle='--', linewidth=0.5)
            ax.add_artist(circle)
        for color, (u, v) in color_points.items():
            ax.plot(u, v, 'o', color='white')
            ax.text(u * 0.9, v * 0.9, f" {color}", fontsize=10, color='white')
        
        if type == "Vectorscope YUV":
            #ax.imshow(hist.T, extent=[-1, 1, -1, 1], origin='lower', cmap='gray',vmin=0, vmax=0.001)
            ax.scatter(U,V, alpha=0.2, color="gray",s=0.15)

        elif type == "Vectorscope Color":
            ax.scatter(U,V, alpha=0.2, color=rgb,s=0.15)

        ax.set_ylim((-1,1))
        ax.set_xlim((-1,1))
        ax.set_aspect('equal')
        ax.set_title(type)
    def plot_waveform(self, ax,frame, type):
        
        _, width, _= frame.shape
        if type == "RGB Parade":
          wave = self.calculate_rgb_waveform(frame,type)
          ax.imshow(wave, aspect='auto', extent=[0, width*3, 0, 255])
        elif type == "Waveform Luma":
          wave = self.calculate_luminance_waveform(frame)
          ax.imshow(wave, aspect='auto', extent=[0, width, 0, 255],cmap= 'gray')   
        elif type == "Waveform RGB":
          wave = self.calculate_rgb_waveform(frame, type)
          ax.imshow(wave, aspect='auto', extent=[0, width, 0, 255]) 


class ControlPanel(QMainWindow):
    def __init__(self, plot_panel):
        super().__init__()
        self.plot_panel = plot_panel
        self.plot_panel.control_panel = self  # Set reference to ControlPanel

        self.setWindowTitle("Control Panel")
        self.central_widget = QWidget(self)
        self.setCentralWidget(self.central_widget)
        self.layout = QVBoxLayout(self.central_widget)

        # Checkboxes for plot type selection
        self.checkboxes = []
        self.plot_types = ["Vectorscope YUV", "Vectorscope Color", "Waveform Luma", "Waveform RGB","RGB Parade"]
        self.checkbox_label = QLabel("Select Plots:")
        self.layout.addWidget(self.checkbox_label)
        for plot_type in self.plot_types:
            checkbox = QCheckBox(plot_type)
            checkbox.stateChanged.connect(self.refresh_plot)
            self.checkboxes.append(checkbox)
            self.layout.addWidget(checkbox)
        # Monitor selection spinner
        self.monitor_label = QLabel("Select Monitor:")
        self.monitor_spinner = QSpinBox()
        self.monitor_spinner.setMinimum(1)
        self.monitor_spinner.setMaximum(len(mss().monitors) - 1)  # Set maximum based on available monitors
        self.monitor_spinner.setValue(1)  # Default to the first monitor
        self.monitor_spinner.valueChanged.connect(self.update_active_monitor)
        self.activeScreen = 1  # Default active monitor
        monitor_layout = QHBoxLayout()
        monitor_layout.addWidget(self.monitor_label)
        monitor_layout.addWidget(self.monitor_spinner)
        self.layout.addLayout(monitor_layout)
        # Buttons
        button_layout = QHBoxLayout()
        self.refresh_button = QPushButton("Refresh")
        self.continuous_mode_button = QPushButton("Continuous Mode")
        self.screenshot_button = QPushButton("Take Screenshot")
        button_layout.addWidget(self.screenshot_button)
        button_layout.addWidget(self.refresh_button)
        button_layout.addWidget(self.continuous_mode_button)      
        self.layout.addLayout(button_layout)

        # Arrangement dropdown
        self.arrangement_label = QLabel("Arrangement:")
        self.arrangement_dropdown = QComboBox()
        self.arrangement_dropdown.addItems(["Vertical", "Horizontal", "2x2"])
        arrangement_layout = QHBoxLayout()
        arrangement_layout.addWidget(self.arrangement_label)
        arrangement_layout.addWidget(self.arrangement_dropdown)
        self.layout.addLayout(arrangement_layout)

        # Connect signals
        self.refresh_button.clicked.connect(self.refresh_plot)
        self.screenshot_button.clicked.connect(self.plot_panel.take_screenshot)
        self.arrangement_dropdown.currentTextChanged.connect(self.change_arrangement)

        # Continuous mode with a timer
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh_plot)
        self.continuous_mode_button.clicked.connect(self.toggle_continuous_mode)
    def closeEvent(self, event):
        """Close the plot panel when this panel is closed."""
        if self.plot_panel:
            self.plot_panel.close()
        super().closeEvent(event)
    def refresh_plot(self):
        """Refresh the plot."""
        selected_plots = self.get_selected_plots()
        num_axes = len(selected_plots)
        if num_axes > 0:
            self.plot_panel.update_layout(num_axes, self.arrangement_dropdown.currentText().lower())
            self.plot_panel.plot_data(selected_plots)

    def change_arrangement(self):
        """Change the plot arrangement."""
        self.refresh_plot()

    def toggle_continuous_mode(self):
        """Toggle continuous mode."""
        if self.timer.isActive():
            self.timer.stop()
            self.continuous_mode_button.setText("Continuous Mode")
            self.enable_vectorscope_color_checkbox(True)
            self.refresh_button.setEnabled(True)  # Enable the refresh button

        else:
            self.enable_vectorscope_color_checkbox(False)
            self.refresh_button.setEnabled(False)  # Enable the refresh button
            self.timer.start(2000)  # Refresh every second
            self.continuous_mode_button.setText("Stop Continuous Mode")

    def get_selected_plots(self):
        """Get a list of selected plot types based on checked checkboxes."""
        return [checkbox.text() for checkbox in self.checkboxes if checkbox.isChecked()]

    def enable_vectorscope_color_checkbox(self, enable):
        """Enable or disable the Vectorscope Color checkbox."""
        for checkbox in self.checkboxes:
            if checkbox.text() == "Vectorscope Color":
                if not enable:
                    checkbox.setChecked(False)  # Deselect the checkbox
                checkbox.setEnabled(enable)
                break

    def update_active_monitor(self, value):
        """Update the active monitor based on the spinner value."""
        self.activeScreen = value
def main():
    app = QApplication(sys.argv)

    plot_panel = PlotPanel()
    control_panel = ControlPanel(plot_panel)
    plot_panel.set_control_panel(control_panel)
    
    screen_geometry = app.desktop().screenGeometry()
    plot_panel.setGeometry(0, 0, screen_geometry.width() // 4, screen_geometry.height())  # Left half of the screen
    #plot_panel.showMaximized()  # Maximize the plot panel window
    plot_panel.show()
    control_panel.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
