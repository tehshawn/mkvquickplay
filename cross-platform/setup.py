"""Setup script for MKV QuickPlay cross-platform version."""

from setuptools import setup, find_packages

with open("../README.md", "r", encoding="utf-8") as f:
    long_description = f.read()

setup(
    name="mkvquickplay",
    version="1.0.0",
    author="Shawn McEntyre",
    description="Quick video preview with Ctrl+Space hotkey - Windows & Linux",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/shawnmcentyre/MKVQuickPlay",
    packages=find_packages(),
    classifiers=[
        "Development Status :: 4 - Beta",
        "Environment :: X11 Applications",
        "Environment :: Win32 (MS Windows)",
        "Intended Audience :: End Users/Desktop",
        "License :: OSI Approved :: MIT License",
        "Operating System :: Microsoft :: Windows",
        "Operating System :: POSIX :: Linux",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Topic :: Multimedia :: Video",
    ],
    python_requires=">=3.8",
    install_requires=[
        "pynput>=1.7.6",
        "pystray>=0.19.5",
        "Pillow>=10.0.0",
        "psutil>=5.9.0",
    ],
    extras_require={
        "windows": [
            "pywin32>=306",
            # pywinselect must be installed separately:
            # pip install git+https://github.com/offerrall/pywinselect.git
        ],
    },
    entry_points={
        "console_scripts": [
            "mkvquickplay=mkvquickplay.app:main",
        ],
        "gui_scripts": [
            "mkvquickplay-gui=mkvquickplay.app:main",
        ],
    },
    include_package_data=True,
    package_data={
        "": ["resources/*"],
    },
)
