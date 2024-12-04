/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A view controller class to show and edit a document.
*/

import UIKit
import Combine

class DetailViewController: UICollectionViewController {
    @IBOutlet var handleConflictsItem: UIBarButtonItem!
    private var fileURLSubscriber: AnyCancellable?
    var document: Document?
    
    lazy var spinner: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .gray
        indicator.hidesWhenStopped = true
        
        guard let superView = view.superview else {
            fatalError("The view controller view isn't in the view hierarchy yet.")
        }
        superView.addSubview(indicator)
        superView.bringSubviewToFront(indicator)
        indicator.center = CGPoint(x: superView.frame.size.width / 2, y: superView.frame.size.height / 2)

        return indicator
    }()

    lazy var plusCircelItem: ImageItem = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 40)
        let image = UIImage(systemName: "plus.circle", withConfiguration: configuration)!
        return ImageItem(name: "plus.circle", thumbnail: image)
    }()
    
    // When a user adds an image, this sample caches the image file locally until the user taps Done to save the document.
    // cacheFolderURL points to the cache folder.
    //
    // Return the cache folder. Create it if it doesn’t exist.
    // The system doesn’t purge the files in the cache folder when the app is running.
    //
    lazy var cacheFolder: URL = {
        var url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        url = url.appendingPathComponent("SimpleiCloudDocument", isDirectory: true)
        
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create the cache folder: \(error)")
        }
        return url
    }()
    
    lazy var diffableImageSource: DiffableImageSource! = {
        return DiffableImageSource(collectionView: collectionView) { (collectionView, indexPath, imageItem) -> ImageCVCell? in
            let cvCell = collectionView.dequeueReusableCell(withReuseIdentifier: "ImageCVCell", for: indexPath)
            guard let cell = cvCell as? ImageCVCell else {
                fatalError("Failed to dequeue ImageCVCell. Check the cell reusable identifier in Main.storyboard.")
            }
            cell.delegate = self
            cell.imageView.image = imageItem.thumbnail
            if indexPath.item == collectionView.numberOfItems(inSection: 0) - 1, self.isEditing {
                cell.backgroundColor = .systemGray6
                cell.imageView.alpha = 1
                cell.deleteButton.alpha = 0
            } else {
                cell.imageView.alpha = self.isEditing ? 0.6 : 1
                cell.deleteButton.alpha = self.isEditing ? 1 : 0
            }
            return cell
        }
    }()
    
    // Remove all cached files by removing the cache folder and then creating an empty folder.
    //
    private func clearCacheFolder() {
        do {
            try FileManager.default.removeItem(atPath: cacheFolder.path)
        } catch {
            print("Failed to delete \(cacheFolder)\n\(error)")
        }
        // Recreate the folder for future use.
        do {
            try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create the cache folder: \(error)")
        }
    }
}

// MARK: - UIViewController overridable
//
extension DetailViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.rightBarButtonItem = editButtonItem
        navigationItem.rightBarButtonItem?.isEnabled = !(document == nil)
        
        let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [flexible, handleConflictsItem, flexible]
        navigationController?.isToolbarHidden = false
        
        // Set up sections. The collection view has only one section in this sample.
        //
        var snapshot = DiffableImageSourceSnapshot()
        snapshot.appendSections([0])
        diffableImageSource.apply(snapshot)
    }
    
    // Subscribe the keyboard notifications when the view is about to appear.
    //
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let document = document else { return }
        
        // Update the UI with the document content.
        // Users can rename the document using other apps like Files.
        // When that happens, UIDocument updates its fileURL automatically.
        // The subscription makes sure the view controller title updates accordingly.
        //
        fileURLSubscriber = document.publisher(for: \.fileURL).receive(on: DispatchQueue.main).sink() { url in
            self.title = url.lastPathComponent
        }
        
        // Observe .stateChangedNotification to update the UI, if necessary.
        NotificationCenter.default.addObserver(
            self, selector: #selector(Self.documentStateChanged(_:)),
            name: UIDocument.stateChangedNotification, object: document)
        
        // documentState eventually turns to .normal, which updates the collection view.
        spinner.startAnimating()
        document.open { _ in
            self.spinner.stopAnimating()
        }
    }

    // Clean up the view controller.
    // Close the document, if necessary, cancel the fileURL KVO subscription,
    // and remove the observation of any notification.
    //
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if let document = document, !document.documentState.contains(.closed) {
            document.close { success in
                if !success {
                    print("Failed to close the document: \(document.fileURL)")
                }
                self.clearCacheFolder()
                self.document = nil
            }
        } else {
            clearCacheFolder()
            self.document = nil
        }
        fileURLSubscriber?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    // Edit session management.
    // editing == true: In an editing session, show plusCircelItem and the delete button.
    // editing == false: The editing is done. Restore the UI and save the document.
    //
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: false)
        
        var snapshot = diffableImageSource.snapshot()
        editing ? snapshot.appendItems([plusCircelItem]) : snapshot.deleteItems([plusCircelItem])
        diffableImageSource.apply(snapshot)
        snapshot.reloadSections([0])
        diffableImageSource.apply(snapshot)

        guard !editing, let document = document else { return }

        // Save the document.
        // Apps normally call `document.updateChangeCount(.done)` to let UIDocument do autosave.
        // This sample chooses to save the document immediately by calling the save method
        // because it has a save button specific for this task.
        //
        spinner.startAnimating()
        document.save(to: document.fileURL, for: .forOverwriting) { _ in
            self.spinner.stopAnimating()
        }
    }
}

//MARK: - ImagePicker
/*
Abstract:
The extension of DetailViewController that implements UIImagePickerControllerDelegate.
*/

extension DetailViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    // UIKit calls this method when the user finishes picking an item with UIImagePickerController.
    // image.jpegData may fail for unsupported image formats. This sample doesn't
    // handle unsupported formats because that isn't the focus.
    //
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        guard let image = info[.originalImage] as? UIImage, let imageData = image.jpegData(compressionQuality: 1),
            let imageURL = info[.imageURL] as? URL else {
                print("Failed to get JPG data and URL of the picked image.")
                return
        }
        
        // Save the full image to the cache folder. The image name from Photo Library should be unique,
        // so this sample doesn’t need to create a unique name for it.
        //
        let imageName = imageURL.lastPathComponent
        let cacheURL = cacheFolder.appendingPathComponent(imageName)
        do {
            try imageData.write(to: cacheURL, options: .atomic)
        } catch {
            print("Failed to save an image file: \(cacheURL)")
        }
        
        // Update document and collectionView, then dismiss the image picker.
        //
        var snapshot = diffableImageSource.snapshot()
        snapshot.insertItems([ImageItem(name: imageName, thumbnail: imageData.thumbnail())], beforeItem: plusCircelItem)
        diffableImageSource.apply(snapshot)
        
        document?.addUnsavedNewImageURL(cacheURL)
        dismiss(animated: true)
    }
    
    // UIKit calls the UIImagePickerControllerDelegate method when the user taps the cancel button in UIImagePickerController.
    //
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true)
    }
}


//MARK: - CollectionView
/*
 Abstract:
 The extension of DetailViewController that manages the collection view.
 */

extension DetailViewController {
    // If the user is editing and tapping the last cell, present an image picker.
    // Otherwise, present the full image.
    // In the latter case, try to load the image in the document bundle first, then check the cache
    // if the image doesn't exist in the document bundle.
    //
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        if isEditing && indexPath.item == collectionView.numberOfItems(inSection: 0) - 1 {
            presentImagePicker()
        } else if let imageItem = diffableImageSource.itemIdentifier(for: indexPath) {
            retrieveAndPresentImage(with: imageItem.name)
        }
    }
    
    private func retrieveAndPresentImage(with imageName: String) {
        document?.retrieveImageAsynchronously(with: imageName) { image in
            DispatchQueue.main.async {
                if let image = image {
                    self.presentImageViewController(image: image)
                    return
                }
                let imageURL = self.cacheFolder.appendingPathComponent(imageName)
                guard let image = UIImage(contentsOfFile: imageURL.path) else { return }
                self.presentImageViewController(image: image)
            }
        }
    }
    
    private func presentImagePicker() {
        let imagePicker = UIImagePickerController()
        imagePicker.delegate = self
        imagePicker.allowsEditing = false
        imagePicker.sourceType = .photoLibrary
        present(imagePicker, animated: true)
    }
    
    private func presentImageViewController(image: UIImage) {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let viewController = storyboard.instantiateViewController(withIdentifier: "FullImageNC")
        guard let navController = viewController as? UINavigationController,
              let imageViewController = navController.topViewController as? ImageViewController else {
                return
        }
        imageViewController.fullImage = image
        present(navController, animated: true)
    }
}

extension DetailViewController: ImagCVCellDelegate {
    func deleteCell(_ cell: UICollectionViewCell) {
        guard let indexPath = collectionView.indexPath(for: cell),
              let imageItem = diffableImageSource.itemIdentifier(for: indexPath) else {
            return
        }

        // If the user added a deleted item in this edit session, remove it from unsavedNewImageURLs.
        // Otherwise, record the deletion.
        //
        let firstIndex = document?.unsavedNewImageURLs.firstIndex {
            $0.lastPathComponent == imageItem.name
        }
        if let index = firstIndex {
            document?.removeUnsavedNewImageURL(at: index)
        } else {
            document?.addUnsavedDeletedImageName(imageItem.name)
        }
        // Update the collectionView.
        //
        var snapshot = diffableImageSource.snapshot()
        snapshot.deleteItems([imageItem])
        diffableImageSource.apply(snapshot)
    }
}

//MARK: DocumentState
/*
 Abstract:
 The extension of DetailViewController that manages the document state changes.
 */

extension DetailViewController {
    @objc
    func documentStateChanged(_ notification: Notification) {
        guard let document = document else { return }
        printDocumentState(for: document)
        
        // The document state is normal.
        // Update the UI with unpresented peer changes, if any.
        //
        if document.documentState == .normal {
            navigationItem.rightBarButtonItem?.isEnabled = true
            handleConflictsItem.isEnabled = false
            if !document.unpresentedPeerChanges.isEmpty {
                let changes = document.unpresentedPeerChanges
                document.clearUnpresentedPeerChanges()
                updateCollectionView(with: changes)
            }
            return
        }
        // The document has conflicts but no error.
        // Update the UI with unpresented peer changes if any.
        //
        if document.documentState == .inConflict {
            navigationItem.rightBarButtonItem?.isEnabled = true
            handleConflictsItem.isEnabled = true
            if !document.unpresentedPeerChanges.isEmpty {
                let changes = document.unpresentedPeerChanges
                document.clearUnpresentedPeerChanges()
                updateCollectionView(with: changes)
            }
            return
        }
        // The document is in a closed state with no error. Clear the UI.
        //
        if document.documentState == .closed {
            navigationItem.rightBarButtonItem?.isEnabled = false
            handleConflictsItem.isEnabled = false
            title = ""
            var snapshot = DiffableImageSourceSnapshot()
            snapshot.appendSections([0])
            diffableImageSource.apply(snapshot)
            return
        }
        // The document has conflicts. Enable the toolbar item.
        //
        if document.documentState.contains(.inConflict) {
            handleConflictsItem.isEnabled = true
        }
        // The document is editingDisabled. Disable the UI for editing.
        //
        if document.documentState.contains(.editingDisabled) {
            navigationItem.rightBarButtonItem?.isEnabled = false
            handleConflictsItem.isEnabled = false
        }
    }
    
    private func updateCollectionView(with changes: Document.Changes) {
        guard let document = document else { return }
        
        if !changes.deletedImageNames.isEmpty {
            let deletedItems = changes.deletedImageNames.map { ImageItem(name: $0, thumbnail: nil) }
            var snapshot = self.diffableImageSource.snapshot()
            snapshot.deleteItems(deletedItems)
            self.diffableImageSource.apply(snapshot)
        }
        if !changes.updatedImageNames.isEmpty {
            document.createImageItemsAsynchronously(with: changes.updatedImageNames) { updatedItems in
                guard let updatedItems = updatedItems else { return }
                DispatchQueue.main.async {
                    var snapshot = self.diffableImageSource.snapshot()
                    snapshot.reloadItems(updatedItems)
                    self.diffableImageSource.apply(snapshot)
                }
            }
        }
        if !changes.newImageURLs.isEmpty {
            let newImageNames = changes.newImageURLs.map { $0.lastPathComponent }
            document.createImageItemsAsynchronously(with: newImageNames) { newItems in
                guard let newItems = newItems else { return }
                DispatchQueue.main.async {
                    var snapshot = self.diffableImageSource.snapshot()
                    snapshot.appendItems(newItems)
                    self.diffableImageSource.apply(snapshot)
                }
            }
        }
    }
    
    private func printDocumentState(for document: Document) {
        if document.documentState == .normal {
            print("documentState: [normal]" )
            return
        }
        var readableStrings = [String]()
        if document.documentState.contains(.inConflict) {
            readableStrings.append("inConflict")
        }
        if document.documentState.contains(.editingDisabled) {
            readableStrings.append("editingDisabled")
        }
        if document.documentState.contains(.progressAvailable) {
            readableStrings.append("progressAvailable")
        }
        if document.documentState.contains(.savingError) {
            readableStrings.append("savingError")
        }
        if document.documentState.contains(.closed) {
            readableStrings.append("closed")
        }
        print("documentState: \(readableStrings)")
    }
}

//MARK: Conflicts
/*
Abstract:
The extension of DetailViewController that handles document conflicts.
*/

extension DetailViewController {
    // This is the action handler of the Conflicts button. Resolve the conflicts and update the UI.
    // For demo purpose, this sample simply makes the latest version the winner.
    // Real-world apps may consider a more sophisticated strategy.
    // See the following link for more discussion:
    // <https://developer.apple.com/documentation/uikit/uidocument#1658506>
    //
    @IBAction func handleConflicts(_ sender: Any) {
        guard let document = document, document.documentState.contains(.inConflict) else {
            handleConflictsItem.isEnabled = false
            return
        }
        
        let revertDocument: (Bool) -> Void = { shouldRevert in
            let message = "The lastest version won. The other versions were removed."
            let alert = UIAlertController(title: "Conflicts Resolved",
                                          message: message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))

            guard shouldRevert else {
                self.present(alert, animated: true)
                return
            }
            
            self.spinner.startAnimating()
            document.revert(toContentsOf: document.fileURL) {_ in
                self.spinner.stopAnimating()
                self.present(alert, animated: true)
            }
        }
        
        spinner.startAnimating()
        resolveConflictsAsynchronously(document: document) { shouldRevert in
            DispatchQueue.main.async {
                self.spinner.stopAnimating()
                revertDocument(shouldRevert)
            }
        }
    }

    // Resolve conflicts asynchronously because coordinated writing may take a long time.
    // Version information is a kind of document metadata, which needs coordinated access in the iCloud environment.
    // The completion handler runs in a secondary queue, so clients should dispatch their code appropriately.
    //
    private func resolveConflictsAsynchronously(document: Document, completionHandler: ((Bool) -> Void)?) {
        DispatchQueue.global().async {
            NSFileCoordinator().coordinate(writingItemAt: document.fileURL,
                                           options: .contentIndependentMetadataOnly, error: nil) { newURL in
                let shouldRevert = self.pickLatestVersion(for: newURL)
                completionHandler?(shouldRevert)
            }
        }
    }

    // Make the latest version current and remove the others.
    //
    private func pickLatestVersion(for documentURL: URL) -> Bool {
        guard let versionsInConflict = NSFileVersion.unresolvedConflictVersionsOfItem(at: documentURL),
              let currentVersion = NSFileVersion.currentVersionOfItem(at: documentURL) else {
            return false
        }
        var shouldRevert = false
        var winner = currentVersion
        for version in versionsInConflict {
            if let date1 = version.modificationDate, let date2 = winner.modificationDate,
               date1 > date2 {
                winner = version
            }
        }
        if winner != currentVersion {
            do {
                try winner.replaceItem(at: documentURL)
                shouldRevert = true
            } catch {
                print("Failed to replace version: \(error)")
            }
        }
        do {
            try NSFileVersion.removeOtherVersionsOfItem(at: documentURL)
        } catch {
            print("Failed to remove other versions: \(error)")
        }
        return shouldRevert
    }
}



